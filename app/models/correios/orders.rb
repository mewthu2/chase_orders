module Correios::Orders
  module_function

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
      servicosAdicionais: params[:forma_envio] == ('39888' || '03662') ? ['019'] : [],
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
        telefone: fone.scan(/[^()]+/)&.last.present? ? fone.scan(/[^()]+/)&.last&.strip : fone.scan(/[^()]+/)&.last,
        email: params[:email],
        cpf: params[:cpf_cnpj].length <= 11 ? params[:cpf_cnpj] : '',
        cnpj: params[:cpf_cnpj].length > 11 ? params[:cpf_cnpj].gsub('/', '') : ''
      },
      itensPedido: params[:itens]
    }

    attempt.update(requisition: body)

    begin
      request = HTTParty.post(ENV.fetch('CORREIOS_CRIAR_PEDIDO'),
                              headers: authentication,
                              body: body.to_json,
                              format: 'string')
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if request.present? && request.force_encoding('UTF-8').include?('Pedido já Cadastrado')
      @request = JSON.parse(request)
    else
      @request = request
    end

    attempt.update(message: @request, status: :success, order_correios_id: @request.body[/\/pedidos\/(\d+)/, 1]) if @request.present? && @request.include?('/efulfillment/v1/pedidos/')
    return if attempt.status == 'success'

    if @request.present? && attempt.status != 2
      attempt.update(status_code: @request['statusCode'],
                     message: @request,
                     exception: @request['excecao'],
                     classification: @request['classificacao'],
                     cause: @request['causa'],
                     url: @request['url'],
                     user: @request['user'])
      if @request['statusCode'] == 200
        attempt.update(status: :success)
      else
        attempt.update(status: :fail) unless attempt.order_correios_id.present?
        attempt.update(status: :success, order_correios_id: /ID: (\d+)/.match(@request['mensagem'])[1]) if @request.present? && @request['mensagem'].present? && @request['mensagem'].include?('Pedido já Cadastrado')
      end
    else
      attempt.update(status: :error, error: 'Requisição vazia') unless attempt.order_correios_id.present?
    end
  end

  def get_tracking(order_correios_id)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg=='
    }
    begin
      HTTParty.get(ENV.fetch('CORREIOS_OBTER_PEDIDO') + order_correios_id.to_s, headers: authentication)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end
  end

  def get_stock(item_code)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    HTTParty.get(ENV.fetch('CORREIOS_ESTOQUE') + "#{item_code}/estoque", headers: authentication)
  end
end
