class B2bTinyService
  BASE_URL = 'https://api.tiny.com.br/api2'.freeze

  # IDs cadastrados na conta Tiny (confirmados via listas.precos.pesquisa.php
  # e comparando id_natureza_operacao de pedidos reais "Padrão" vs
  # "Transferencia") — não existe endpoint de leitura pra natureza de
  # operação, então esses valores foram lidos diretamente de pedidos já
  # criados manualmente no Tiny.
  TRANSFER_PRICE_LIST_ID = '8198'.freeze
  TINY_SITUACAO_CODES = {
    'aberto' => 'aberto', 'aprovado' => 'aprovado', 'preparando_envio' => 'preparando_envio',
    'faturado' => 'faturado', 'pronto_para_envio' => 'pronto_envio', 'enviado' => 'enviado',
    'nao_entregue' => 'nao_entregue', 'cancelado' => 'cancelado',
    'dados_incompletos' => 'dados_incompletos'
  }.freeze
  # Código de forma_envio que o Tiny grava para cada tipo de logística das formas de envio
  # (tipo_logistica de formas.envio.pesquisa), conferido em pedidos reais da conta B2B:
  # 1 Correios => C, 2 Transportadora => T, 5 Correios Log => E, 6 Retirar pessoalmente => S.
  FORMA_ENVIO_CODES = { '1' => 'C', '2' => 'T', '5' => 'E', '6' => 'S' }.freeze
  CORREIOS_CARRIER_NAME = 'EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS'.freeze

  class ShippingError < StandardError; end

  NATUREZA_OPERACAO_IDS = { 'standard' => '898357546', 'transfer' => '790850411' }.freeze

  # Transferência B2B -> B2C segue o pedido nº 1859 da conta B2B: destinatário fixo na filial B2C
  # e o marcador "(Transferencia b2c)" (id lido de pedido.obter.php). Nasce em preparando_envio
  # para cair na fila de criação dos Correios B2B (CreateCorreiosLogOrdersJob2).
  B2C_TRANSFER_TAG = '(Transferencia b2c)'.freeze
  B2C_TRANSFER_MARKER_ID = '182662'.freeze
  B2C_TRANSFER_RECIPIENT = {
    nome: 'CHASE BRASIL COMERCIO DE ARTIGOS ESPORTIVOS LTDA', tipo_pessoa: 'J',
    cpf_cnpj: '25.405.327/0003-36', ie: '0029090240268',
    endereco: 'Av. Raja Gabaglia', numero: '4343', complemento: 'sala 419', bairro: 'Santa Lucia',
    cidade: 'Belo Horizonte', uf: 'MG', cep: '30.350-577'
  }.freeze

  def initialize
    @token = ENV.fetch('TOKEN_TINY2_PRODUCTION')
  end

  def shipping_methods
    response = HTTParty.get("#{BASE_URL}/formas.envio.pesquisa.php",
                             query: { token: @token, formato: 'json' })
    parsed = JSON.parse(response.body).with_indifferent_access
    return [] unless parsed.dig(:retorno, :status) == 'OK'

    Array(parsed.dig(:retorno, :registros)).map do |r|
      { name: r[:nome], method: r[:id], logistics_type: r[:tipo_logistica].to_s }
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
    # O Tiny exige o JSON embrulhado em {"pedido": {...}}; sem a raiz ele não enxerga cliente nem itens.
    response = do_post('pedido.incluir.php', pedido: { pedido: build_pedido(b2b_order) }.to_json)
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

  def create_b2c_transfer(b2b_order)
    response = do_post('pedido.incluir.php', pedido: { pedido: build_b2c_transfer_pedido(b2b_order) }.to_json)
    parse_pedido_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_b2c_transfer exception: #{e.message}"
    { success: false, error: e.message }
  end

  def create_carrier_contact(carrier)
    response = do_post('contato.incluir.php', contato: build_contato(carrier).to_json)
    parse_contato_response(response)
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#create_carrier_contact exception: #{e.message}"
    { success: false, error: e.message }
  end

  def update_order_status(tiny_reference_id, status)
    response = do_post('pedido.alterar.situacao.php',
                       id: tiny_reference_id, situacao: TINY_SITUACAO_CODES.fetch(status.to_s))
    retorno = parse_retorno(response)
    return { success: false, error: "Resposta inválida do Tiny (HTTP #{response.code})." } unless retorno
    return { success: true } if retorno[:status] == 'OK'

    { success: false, error: tiny_error_message(retorno) }
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#update_order_status exception: #{e.message}"
    { success: false, error: e.message }
  end

  def order_status(tiny_reference_id)
    response = HTTParty.get("#{BASE_URL}/pedido.obter.php",
                             query: { token: @token, formato: 'json', id: tiny_reference_id })
    retorno = JSON.parse(response.body).with_indifferent_access[:retorno]
    return nil unless retorno[:status] == 'OK'

    pedido = retorno[:pedido]
    { situacao: pedido[:situacao], tracking_code: pedido[:codigo_rastreamento].presence }
  rescue StandardError => e
    Rails.logger.error "B2bTinyService#order_status exception: #{e.message}"
    nil
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

  # forma_envio (código por tipo de logística), forma_frete (serviço) e nome_transportador do pedido.
  # Sem forma escolhida no Honey não inventamos nada. Se a forma não puder ser resolvida com
  # segurança, levantamos ShippingError: melhor não enviar do que criar um pedido com frete errado.
  def shipping_fields(order)
    return {} if order.carrier_shipping_method.blank?

    methods = shipping_methods
    raise ShippingError, 'Não foi possível consultar as formas de envio no Tiny. Tente novamente.' if methods.empty?

    forma = methods.find { |m| m[:method].to_s == order.carrier_shipping_method.to_s }
    raise ShippingError, "Forma de envio (#{order.carrier_shipping_method}) não encontrada no Tiny. Escolha a forma de envio novamente." unless forma

    code = FORMA_ENVIO_CODES[forma[:logistics_type]]
    raise ShippingError, "A forma de envio \"#{forma[:name]}\" (tipo de logística #{forma[:logistics_type]}) ainda não é suportada pelo Honey." unless code

    fields = { forma_envio: code }
    case code
    when 'C'
      fields[:nome_transportador] = CORREIOS_CARRIER_NAME
    when 'E'
      raise ShippingError, 'Escolha o serviço de frete (SEDEX, PAC...) para Correios Log.' if order.freight_service.blank?

      fields[:forma_frete] = order.freight_service
      fields[:nome_transportador] = CORREIOS_CARRIER_NAME
    when 'T'
      carrier_name = (order.carrier&.name || order.carrier_name).to_s.strip
      raise ShippingError, 'Escolha a transportadora da forma de envio "Transportadora".' if carrier_name.blank?

      # Como no pedido 1859: a criação dos Correios B2B exige forma_frete, que leva o nome da transportadora.
      fields[:nome_transportador] = carrier_name
      fields[:forma_frete] = carrier_name
    end
    fields.compact_blank
  end

  def build_pedido(b2b_order)
    client = b2b_order.client

    pedido = {
      situacao: 'aberto',
      data_pedido: b2b_order.created_at.strftime('%d/%m/%Y'),
      id_natureza_operacao: NATUREZA_OPERACAO_IDS[b2b_order.price_list],
      itens: pedido_itens(b2b_order),
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
      **shipping_fields(b2b_order),
      frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
      valor_frete: b2b_order.freight_value.to_f,
      obs: build_obs(b2b_order)
    }

    pedido[:id_lista_preco] = TRANSFER_PRICE_LIST_ID if b2b_order.transfer?

    if b2b_order.different_shipping_address?
      pedido[:endereco_entrega] = {
        nome_destinatario: client.display_name,
        endereco: b2b_order.shipping_street.presence || '',
        numero: b2b_order.shipping_number.presence || '',
        complemento: b2b_order.shipping_complement.presence || '',
        bairro: b2b_order.shipping_neighbourhood.presence || '',
        cidade: b2b_order.shipping_city.presence || '',
        uf: b2b_order.shipping_state.presence || '',
        cep: b2b_order.shipping_zip.presence || ''
      }
    end

    pedido
  end

  def pedido_itens(b2b_order)
    b2b_order.b2b_order_items.map do |i|
      { item: { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity,
                 valor_unitario: (i.price.to_f - i.discount.to_f) } }
    end
  end

  def build_b2c_transfer_pedido(b2b_order)
    entrega = B2C_TRANSFER_RECIPIENT.except(:nome).merge(nome_destinatario: B2C_TRANSFER_TAG)

    {
      situacao: 'preparando_envio',
      data_pedido: b2b_order.created_at.strftime('%d/%m/%Y'),
      id_natureza_operacao: NATUREZA_OPERACAO_IDS['transfer'],
      id_lista_preco: TRANSFER_PRICE_LIST_ID,
      itens: pedido_itens(b2b_order),
      cliente: B2C_TRANSFER_RECIPIENT,
      endereco_entrega: entrega,
      marcadores: [{ marcador: { id: B2C_TRANSFER_MARKER_ID, descricao: B2C_TRANSFER_TAG } }],
      **shipping_fields(b2b_order),
      frete_por_conta: b2b_order.shipper? ? 'R' : 'D',
      valor_frete: b2b_order.freight_value.to_f,
      obs: [B2C_TRANSFER_TAG, "Transferência B2C ##{b2b_order.id}", b2b_order.notes.presence].compact.join(' | '),
      obs_interna: B2C_TRANSFER_TAG
    }
  end

  # Não há vendedor cadastrado no Tiny desta conta (vendedores.pesquisa.php
  # não retorna registros), então não há id_vendedor pra mapear — o nome
  # digitado na Honey só fica visível via observações.
  def build_obs(b2b_order)
    base = b2b_order.notes.presence || "Pedido B2B ##{b2b_order.id}"
    return base if b2b_order.salesperson_name.blank?

    "Vendedor: #{b2b_order.salesperson_name} | #{base}"
  end

  def build_nota_fiscal(b2b_order)
    transfer_location = b2b_order.transfer_location

    items = b2b_order.b2b_order_items.map do |i|
      { codigo: i.sku, descricao: i.name, unidade: 'UN', quantidade: i.quantity.to_s,
        valor_unitario: format('%.2f', i.price.to_f - i.discount.to_f), tipo: 'P', cfop: '5152' }
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
    retorno = parse_retorno(response)
    return { success: false, error: "Resposta inválida do Tiny (HTTP #{response.code})." } unless retorno

    if retorno[:status] == 'OK'
      registro = retorno.dig(:registros, :registro)
      { success: true, tiny_reference_id: registro&.dig(:id)&.to_s, tiny_reference_number: registro&.dig(:numero)&.to_s }
    else
      { success: false, error: tiny_error_message(retorno) }
    end
  end

  # O corpo de uma resposta do Tiny pode não ser JSON (ex.: página de erro do gateway).
  def parse_retorno(response)
    JSON.parse(response.body).with_indifferent_access[:retorno]
  rescue JSON::ParserError, TypeError
    nil
  end

  # O Tiny devolve os erros em formatos diferentes: retorno.erros (hash ou lista) e, no
  # pedido.incluir, dentro de retorno.registros.registro.erros. Junta todos os que existirem.
  def tiny_error_message(retorno)
    messages = collect_tiny_errors(retorno).uniq
    return messages.join(', ') if messages.any?

    "Erro desconhecido na API Tiny (status: #{retorno[:status].presence || 'ausente'}, código: #{retorno[:codigo_erro].presence || 'ausente'})."
  end

  def collect_tiny_errors(node)
    case node
    when Hash then node.flat_map { |key, value| key.to_s == 'erro' ? Array(value).map(&:to_s) : collect_tiny_errors(value) }
    when Array then node.flat_map { |item| collect_tiny_errors(item) }
    else []
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
