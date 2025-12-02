module Correios::Orders
  module_function

  MAX_LOG_SIZE = 100

  def truncate_value(value)
    v = value.to_s
    v.length > MAX_LOG_SIZE ? v[0...MAX_LOG_SIZE] : v
  end

  def safe_update(attempt, data)
    data.each do |k, v|
      data[k] = truncate_value(v)
    end
    attempt.update(data)
  rescue ActiveRecord::ValueTooLong
    attempt.update(error: "Oversized Value for #{data.keys.join(', ')}", status: :error)
  end

  def create_orders(params, attempt)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    correios_cod_armazem = ENV.fetch('CORREIOS_COD_ARMAZEM')
    correios_cartao_postagem = ENV.fetch('CORREIOS_CARTAO_POSTAGEM')
    correios_cnpj_transportadora = ENV.fetch('CORREIOS_CNPJ_TRANSPORTADORA')
    fone = params[:fone].present? ? params[:fone] : ''

    body = {
      codigoArmazem: correios_cod_armazem,
      numero: params[:invoice],
      dataSolicitacao: params[:data_pedido],
      valordeclarado: params[:valor].gsub('.', ','),
      cartaoPostagem: correios_cartao_postagem,
      codigoservico: params[:forma_envio],
      numeroPLP: '',
      numeroSerie: '1',
      cnpjTransportadora: correios_cnpj_transportadora,
      servicosAdicionais: ['39888', '06602'].include?(params[:forma_envio]) ? ['019'] : ['064'],
      destinatario: {
        nome: params[:nome],
        logradouro: params[:endereco],
        numeroEndereco: params[:numero],
        complemento: params[:complemento],
        bairro: params[:bairro],
        cep: params[:cep],
        cidade: params[:cidade],
        uf: params[:uf],
        ddd: fone.match(/\(([^)]+)\)/).present? ? fone.match(/\(([^)]+)\)/)[1] : fone,
        telefone: fone.scan(/[^()]+/)&.last&.strip || fone,
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
        order_correios_id: @request['mensagem'][/ID: (\d+)/, 1]
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

  def get_tracking(order_correios_id)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    begin
      HTTParty.get(ENV.fetch('CORREIOS_OBTER_PEDIDO') + order_correios_id.to_s, headers: authentication)
    rescue StandardError => e
      safe_update(attempt, error: e.message, status: :error)
    end
  end

  def get_stock(item_code)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    HTTParty.get("#{ENV.fetch('CORREIOS_ESTOQUE')}#{item_code}/estoque", headers: authentication)
  end
end
