class TinyService
  BASE_URL = 'https://api.tiny.com.br/api2'.freeze

  # Situações do Tiny
  SITUACAO_ABERTO    = 'aberto'.freeze
  SITUACAO_APROVADO  = 'aprovado'.freeze

  def initialize
    @token = ENV.fetch('TOKEN_TINY2_PRODUCTION')
  end

  # Cria pedido no Tiny com situação "aberto"
  # Retorna { success: true, tiny_order_id: "...", tiny_order_number: "..." }
  # ou      { success: false, error: "..." }
  def create_order(order_pdv)
    Rails.logger.info "TinyService#create_order | order_pdv_id: #{order_pdv.id}"

    pedido = build_pedido(order_pdv)

    response = post('pedido.incluir.php', { pedido: pedido }.to_json)

    Rails.logger.info "Tiny create_order response: #{response.inspect}"

    if response['retorno'] && response['retorno']['status'] == 'OK'
      registro = response.dig('retorno', 'registros', 'registro')

      tiny_id     = registro&.dig('id')&.to_s
      tiny_number = registro&.dig('numero')&.to_s

      Rails.logger.info "Pedido criado no Tiny: id=#{tiny_id} numero=#{tiny_number}"

      { success: true, tiny_order_id: tiny_id, tiny_order_number: tiny_number }
    else
      error = response.dig('retorno', 'erros', 'erro') ||
              response.dig('retorno', 'registros', 'registro', 'erros', 'erro') ||
              'Erro desconhecido na API Tiny'
      Rails.logger.error "Tiny API error: #{error}"
      { success: false, error: error.is_a?(Array) ? error.map { |e| e['erro'] }.join(', ') : error.to_s }
    end
  rescue StandardError => e
    Rails.logger.error "TinyService#create_order exception: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end

  # Atualiza situação do pedido para "aprovado"
  def approve_order(tiny_order_id)
    Rails.logger.info "TinyService#approve_order | tiny_order_id: #{tiny_order_id}"

    response = post_params('pedido.alterar.situacao.php', {
      id:       tiny_order_id.to_i,
      situacao: SITUACAO_APROVADO
    })

    Rails.logger.info "Tiny approve_order response: #{response.inspect}"

    if response['retorno'] && response['retorno']['status'] == 'OK'
      { success: true }
    else
      error = response.dig('retorno', 'erros', 'erro') || 'Erro desconhecido'
      { success: false, error: error.to_s }
    end
  rescue StandardError => e
    Rails.logger.error "TinyService#approve_order exception: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def build_pedido(order_pdv)
    items = order_pdv.order_pdv_items.includes(:product).map do |item|
      {
        item: {
          codigo:         item.sku,
          descricao:      item.product_name,
          unidade:        'UN',
          quantidade:     item.quantity,
          valor_unitario: item.price.to_f
        }
      }
    end

    pedido = {
      situacao:      SITUACAO_ABERTO,
      data_pedido:   order_pdv.created_at.strftime('%d/%m/%Y'),
      data_prevista: order_pdv.created_at.strftime('%d/%m/%Y'),
      obs:           order_pdv.order_note.presence || "Pedido PDV ##{order_pdv.id}",
      itens:         items
    }

    # Cliente
    if order_pdv.client.present?
      client = order_pdv.client
      pedido[:cliente] = {
        nome:                  client.display_name,
        tipo_pessoa:           client.registration.present? ? 'J' : 'F',
        cpf_cnpj:              client.registration.presence || '',
        ie:                    client.state_registration.presence || '',
        im:                    client.municipal_registration.presence || '',
        email:                 client.email.presence || '',
        fone:                  client.phone.presence || '',
        endereco:              client.street.presence || '',
        numero:                client.number.presence || '',
        bairro:                client.neighbourhood.presence || '',
        cidade:                client.city.presence || '',
        uf:                    client.state.presence || '',
        cep:                   client.zip.presence || ''
      }
    elsif order_pdv.customer_name.present?
      pedido[:cliente] = {
        nome:       order_pdv.customer_name,
        tipo_pessoa: 'F',
        email:      order_pdv.customer_email.presence || '',
        fone:       order_pdv.customer_phone.presence || ''
      }
    end

    # Formas de pagamento
    if order_pdv.order_parcels.any?
      pedido[:forma_pagamento] = order_pdv.order_parcels.map do |parcel|
        {
          forma_pagamento: {
            meio_pagamento: map_payment_method(parcel.payment_method),
            valor:          parcel.amount.to_f,
            obs:            parcel.notes.presence || ''
          }
        }
      end
    else
      pedido[:forma_pagamento] = [
        {
          forma_pagamento: {
            meio_pagamento: map_payment_method(order_pdv.payment_method),
            valor:          order_pdv.total_price.to_f
          }
        }
      ]
    end

    # Endereço de entrega (se tiver)
    if order_pdv.address1.present?
      parts = order_pdv.address1.to_s.split(', ')
      pedido[:enderecoEntrega] = {
        endereco: parts[0] || '',
        numero:   parts[1] || '',
        cidade:   order_pdv.city.presence || '',
        uf:       order_pdv.state.presence || '',
        cep:      order_pdv.zip.presence || ''
      }
    end

    pedido
  end

  def map_payment_method(method)
    {
      'dinheiro'       => 'dinheiro',
      'credit_card'    => 'cartao_credito',
      'debit_card'     => 'cartao_debito',
      'pix'            => 'pix',
      'boleto'         => 'boleto_bancario',
      'bank_transfer'  => 'transferencia_bancaria',
      'check'          => 'cheque',
      'parcels'        => 'cartao_credito'
    }.fetch(method.to_s, 'outros')
  end

  # POST com payload JSON embrulhado em "pedido" (criar pedido)
  def post(endpoint, json_body)
    do_post(endpoint, token: @token, formato: 'JSON', pedido: json_body)
  end

  # POST com parâmetros arbitrários form-encoded (alterar situação, etc.)
  def post_params(endpoint, extra_params = {})
    do_post(endpoint, { token: @token, formato: 'JSON' }.merge(extra_params))
  end

  def do_post(endpoint, form_params)
    uri  = URI("#{BASE_URL}/#{endpoint}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request.set_form_data(form_params)

    Rails.logger.info "Tiny POST #{endpoint}"
    response = http.request(request)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    Rails.logger.error "Tiny JSON parse error: #{e.message}"
    { 'retorno' => { 'status' => 'Erro', 'erros' => { 'erro' => 'Resposta inválida da API Tiny' } } }
  end
end
