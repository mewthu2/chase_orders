class B2bTinyService
  BASE_URL = 'https://api.tiny.com.br/api2'.freeze

  def initialize
    @token = ENV.fetch('TOKEN_TINY2_PRODUCTION')
  end

  def shipping_methods
    response = HTTParty.get("#{BASE_URL}/formas.envio.pesquisa.php",
                             query: { token: @token, formato: 'json' })
    parsed = JSON.parse(response.body).with_indifferent_access
    return [] unless parsed.dig(:retorno, :status) == 'OK'

    Array(parsed.dig(:retorno, :registros)).map do |r|
      { name: r[:nome], method: r[:id] }
    end
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#shipping_methods exception: #{e.message}"
    []
  end

  def search_clients(query)
    response = HTTParty.get("#{BASE_URL}/contatos.pesquisa.php",
                             query: { token: @token, pesquisa: query, formato: 'json' })
    parsed = JSON.parse(response.body).with_indifferent_access
    return [] unless parsed.dig(:retorno, :status) == 'OK'

    Array(parsed.dig(:retorno, :contatos)).filter_map do |entry|
      c = entry[:contato]
      next unless c

      {
        tiny_id: c[:id],
        name: c[:nome],
        tipo_pessoa: c[:tipo_pessoa],
        registration: c[:cpf_cnpj],
        street: c[:endereco],
        number: c[:numero],
        complement: c[:complemento],
        neighbourhood: c[:bairro],
        city: c[:cidade],
        state: c[:uf],
        zip: c[:cep],
        email: c[:email],
        phone: c[:fone]
      }
    end
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#search_clients exception: #{e.message}"
    []
  end

  def create_sale_order(b2b_order)
    response = do_post('pedido.incluir.php', pedido: build_pedido(b2b_order).to_json)
    parse_pedido_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_sale_order exception: #{e.message}"
    { success: false, error: e.message }
  end

  def create_stock_transfer(b2b_order)
    response = do_post('nota.fiscal.incluir.php', nota: build_nota_fiscal(b2b_order).to_json)
    parse_nota_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_stock_transfer exception: #{e.message}"
    { success: false, error: e.message }
  end

  def create_carrier_contact(carrier)
    response = do_post('contato.incluir.php', contato: build_contato(carrier).to_json)
    parse_contato_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_carrier_contact exception: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def build_contato(carrier)
    {
      sequencia: '1',
      nome: carrier.name,
      tipo_pessoa: 'J',
      cpf_cnpj: carrier.registration.to_s.gsub(/\D/, ''),
      ie: carrier.state_registration.presence || '',
      endereco: carrier.street,
      numero: carrier.number,
      complemento: carrier.complement.presence || '',
      bairro: carrier.neighbourhood,
      cep: carrier.zip.to_s.gsub(/\D/, ''),
      cidade: carrier.city,
      uf: carrier.state,
      fone: carrier.phone.presence || '',
      email: carrier.email.presence || '',
      situacao: 'A',
      tipos_contato: [{ tipo: 'Transportadora' }]
    }
  end

  def parse_contato_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    if retorno[:status] == 'OK'
      registro = retorno.dig(:registros, :registro)
      { success: true, tiny_contact_id: registro&.dig(:id)&.to_s }
    else
      registro = retorno.dig(:registros, :registro)
      erro = registro&.dig(:erros)&.dig(:erro) || retorno.dig(:erros, :erro)
      { success: false, error: Array(erro).join(', ').presence || erro.to_s.presence || 'Erro desconhecido na API Tiny' }
    end
  end

  def do_post(endpoint, body_params)
    HTTParty.post("#{BASE_URL}/#{endpoint}",
                   body: { token: @token, formato: 'json' }.merge(body_params))
  end

  def build_pedido(b2b_order)
    client = b2b_order.client

    {
      situacao: 'aberto',
      data_pedido: b2b_order.created_at.strftime('%d/%m/%Y'),
      itens: b2b_order.b2b_order_items.map do |i|
        { item: { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity, valor_unitario: i.price.to_f } }
      end,
      cliente: {
        nome: client.display_name,
        tipo_pessoa: client.registration.present? ? 'J' : 'F',
        cpf_cnpj: client.registration.presence || '',
        ie: client.state_registration.presence || '',
        endereco: client.street.presence || '',
        numero: client.number.presence || '',
        bairro: client.neighbourhood.presence || '',
        cidade: client.city.presence || '',
        uf: client.state.presence || '',
        cep: client.zip.presence || ''
      },
      forma_envio: 'T',
      nome_transportador: b2b_order.carrier&.name || b2b_order.carrier_name,
      forma_frete: b2b_order.carrier_shipping_method,
      frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
      valor_frete: b2b_order.freight_value.to_f,
      obs: b2b_order.notes.presence || "Pedido B2B ##{b2b_order.id}"
    }
  end

  def build_nota_fiscal(b2b_order)
    transfer_location = b2b_order.transfer_location

    items = b2b_order.b2b_order_items.map do |i|
      { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity.to_s,
        valor_unitario: format('%.2f', i.price), tipo: 'P', cfop: '5152' }
    end

    valor_produtos = items.sum { |it| it[:valor_unitario].to_f * it[:quantidade].to_f }
    valor_icms = (valor_produtos * 0.18).round(2)
    valor_nota = (valor_produtos + valor_icms).round(2)

    {
      nota_fiscal: {
        tipo: 'S',
        natureza_operacao: 'CFOP 5152 - Transferência de mercadoria adquirida ou recebida de terceiros',
        data_emissao: Time.current.strftime('%d/%m/%Y'),
        cliente: {
          nome: transfer_location.name,
          tipo_pessoa: 'J',
          cpf_cnpj: transfer_location.registration,
          ie: transfer_location.state_registration.presence || '',
          endereco: transfer_location.street,
          numero: transfer_location.number,
          complemento: transfer_location.complement.presence || '',
          bairro: transfer_location.neighbourhood,
          cidade: transfer_location.city,
          uf: transfer_location.state,
          cep: transfer_location.zip
        },
        itens: items.map { |item| { item: item } },
        transportador: { nome: b2b_order.carrier&.name || b2b_order.carrier_name },
        forma_frete: b2b_order.carrier_shipping_method,
        frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
        valor_frete: b2b_order.freight_value.to_f,
        valor_produtos: format('%.2f', valor_produtos),
        valor_icms: format('%.2f', valor_icms),
        base_icms: format('%.2f', valor_produtos),
        valor_nota: format('%.2f', valor_nota),
        valor_faturado: format('%.2f', valor_nota),
        obs: "Transferência B2B ##{b2b_order.id} | #{b2b_order.notes}"
      }
    }
  end

  def parse_pedido_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    if retorno[:status] == 'OK'
      registro = retorno.dig(:registros, :registro)
      { success: true, tiny_reference_id: registro&.dig(:id)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      erro = retorno.dig(:erros, :erro)
      { success: false, error: Array(erro).join(', ').presence || erro.to_s.presence || 'Erro desconhecido na API Tiny' }
    end
  end

  def parse_nota_response(response)
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    registro = retorno.dig(:registros, :registro)
    erro = registro&.dig(:erro)

    if retorno[:status_processamento] == '3' && retorno[:status] == 'OK'
      { success: true, tiny_reference_id: registro&.dig(:numero)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      { success: false, error: erro.presence || 'Erro desconhecido na API Tiny' }
    end
  end
end
