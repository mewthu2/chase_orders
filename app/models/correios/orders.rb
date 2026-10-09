module Correios::Orders
  module_function

  MAX_LOG_SIZE = 100

  def truncate_value(attempt, key, value)
    v = value.to_s
    column = attempt.class.columns_hash[key.to_s]
    return v if column&.type == :text

    v.length > MAX_LOG_SIZE ? v[0...MAX_LOG_SIZE] : v
  end

  def safe_update(attempt, data)
    data.each do |k, v|
      data[k] = truncate_value(attempt, k, v)
    end
    attempt.update(data)
  rescue ActiveRecord::ValueTooLong
    attempt.update(error: "Valor grande demais para #{data.keys.join(', ')}", status: :error)
  end

  # recipient_name substitui só o nome do destinatário enviado aos Correios (params[:nome] fica intacto).
  def create_orders(params, attempt, recipient_name: nil)
    is_transportadora = params[:cnpj_transportadora].present?
    from_tiny2 = attempt.kinds == 'create_correios_order_tiny2'

    authentication = {
      'numeroCartaoPostagem' => from_tiny2 ? ENV.fetch('CORREIOS_CARTAO_POSTAGEM_2') : ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(from_tiny2 ? ENV.fetch('TOKEN_LOG_PRODUCTION2') : ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    correios_cod_armazem = ENV.fetch('CORREIOS_COD_ARMAZEM')
    correios_cartao_postagem = from_tiny2 ? ENV.fetch('CORREIOS_CARTAO_POSTAGEM_2') : ENV.fetch('CORREIOS_CARTAO_POSTAGEM')
    correios_cnpj_transportadora = is_transportadora ? params[:cnpj_transportadora] : ENV.fetch('CORREIOS_CNPJ_TRANSPORTADORA')
    fone = params[:fone].present? ? params[:fone] : ''

    # O serviço 74926 (redespacho para transportadora) exige data+hora e não aceita
    # o adicional de Valor Declarado (064), diferente dos serviços diretos dos Correios
    data_solicitacao = is_transportadora ? "#{params[:data_pedido]} 08:00:00" : params[:data_pedido]
    valor_declarado = is_transportadora ? '' : params[:valor].gsub('.', ',')
    servicos_adicionais = if ['39888', '06602'].include?(params[:forma_envio])
                            ['019']
                          elsif params[:forma_envio] == '74926'
                            []
                          else
                            ['064']
                          end

    body = {
      codigoArmazem: correios_cod_armazem,
      numero: params[:invoice],
      dataSolicitacao: data_solicitacao,
      valordeclarado: valor_declarado,
      cartaoPostagem: correios_cartao_postagem,
      codigoservico: params[:forma_envio],
      numeroPLP: '',
      numeroSerie: '1',
      cnpjTransportadora: correios_cnpj_transportadora,
      servicosAdicionais: servicos_adicionais,
      destinatario: {
        nome: recipient_name.presence || params[:nome],
        logradouro: params[:endereco],
        numeroEndereco: params[:numero].to_s.gsub(/\D/, '').first(6).presence || 'S/N',
        complemento: params[:complemento].to_s.first(60),
        bairro: params[:bairro],
        cep: params[:cep],
        cidade: params[:cidade],
        uf: params[:uf],
        ddd: fone.to_s.gsub(/\D/, '')[0, 2],
        telefone: fone.to_s.gsub(/\D/, '')[2..],
        email: params[:email],
        cpf: params[:cpf_cnpj].length <= 11 ? params[:cpf_cnpj] : '',
        cnpj: params[:cpf_cnpj].length > 11 ? params[:cpf_cnpj].gsub('/', '') : ''
      },
      itensPedido: params[:itens]
    }

    safe_update(attempt, requisition: body)

    begin
      request = HTTParty.post(
        ENV.fetch('CORREIOS_CRIAR_PEDIDO'),
        headers: authentication,
        body: body.to_json,
        format: :plain
      )
    rescue StandardError => e
      safe_update(attempt, error: e.message, status: :error)
      return
    end

    if request.code == 400
      safe_update(
        attempt,
        error: 'Erro 400 - Bad Request',
        status_code: request.code,
        message: request.body,
        status: :fail
      )
      return
    end

    if request.present? && request.body.force_encoding('UTF-8').include?('Pedido já Cadastrado')
      @request = JSON.parse(request.body) rescue { 'mensagem' => request.body }
    else
      begin
        @request = JSON.parse(request.body)
      rescue JSON::ParserError
        @request = { 'mensagem' => request.body }
      end
    end

    if @request['mensagem'].to_s.include?('/efulfillment/v1/pedidos/')
      safe_update(
        attempt,
        message: @request,
        status: :success,
        order_correios_id: @request['mensagem'][/pedidos\/(\d+)/, 1]
      )
    end

    return if attempt.status == 'success'

    if @request.present?
      safe_update(
        attempt,
        status_code: @request['statusCode'],
        message: @request,
        exception: @request['excecao'],
        classification: @request['classificacao'],
        cause: @request['causa'],
        url: @request['url'],
        user: @request['user']
      )

      if @request['statusCode'] == '200'
        order_id = @request['mensagem'][/pedidos\/(\d+)/, 1]
        safe_update(attempt, status: :success, status_code: 200, order_correios_id: order_id)
      elsif @request['mensagem'].to_s.include?('Pedido já Cadastrado')
        safe_update(
          attempt,
          status: :success,
          order_correios_id: /ID: (\d+)/.match(@request['mensagem'])[1]
        )
      else
        safe_update(attempt, status: :fail)
      end
    else
      safe_update(attempt, status: :error, error: 'Requisição vazia') unless attempt.order_correios_id.present?
    end
  end

  def get_tracking(order_correios_id, from_tiny2: false)
    authentication = {
      'numeroCartaoPostagem' => from_tiny2 ? ENV.fetch('CORREIOS_CARTAO_POSTAGEM_2') : ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(from_tiny2 ? ENV.fetch('TOKEN_LOG_PRODUCTION2') : ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    begin
      HTTParty.get(ENV.fetch('CORREIOS_OBTER_PEDIDO') + order_correios_id.to_s, headers: authentication)
    rescue StandardError => e
      safe_update(attempt, error: e.message, status: :error)
    end
  end

  def get_stock(item_code, from_tiny2: false, timeout: nil)
    authentication = {
      'numeroCartaoPostagem' => from_tiny2 ? ENV.fetch('CORREIOS_CARTAO_POSTAGEM_2') : ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(from_tiny2 ? ENV.fetch('TOKEN_LOG_PRODUCTION2') : ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    options = { headers: authentication }
    options[:timeout] = timeout if timeout
    HTTParty.get("#{ENV.fetch('CORREIOS_ESTOQUE')}#{item_code}/estoque", options)
  end
end
