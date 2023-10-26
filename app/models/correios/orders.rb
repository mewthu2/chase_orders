class Correios::Orders
  def self.create_orders(params, attempt)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    correios_cod_armazem = ENV.fetch('CORREIOS_COD_ARMAZEM')
    correios_cartao_postagem = ENV.fetch('CORREIOS_CARTAO_POSTAGEM')
    correios_cnpj_transportadora = ENV.fetch('CORREIOS_CNPJ_TRANSPORTADORA')

    body = {
      codigoArmazem: correios_cod_armazem,
      numero: params[:invoice],
      dataSolicitacao: params[:data_pedido],
      valorDeclarado: params[:valor],
      cartaoPostagem: correios_cartao_postagem,
      codigoServico: '39888',
      numeroPLP: '',
      numeroSerie: '1',
      cnpjTransportadora: correios_cnpj_transportadora,
      servicosAdicionais: ['019'],
      destinatario: {
        nome: params[:nome],
        logradouro: params[:endereco],
        numeroEndereco: params[:numero],
        complemento: params[:complemento],
        bairro: params[:bairro],
        cep: params[:cep],
        cidade: params[:cidade],
        uf: params[:uf],
        ddd: params[:fone].match(/\(([^)]+)\)/)[1],
        telefone: params[:fone].scan(/[^()]+/).last.strip,
        email: params[:email],
        cpf: params[:cpf_cnpj],
        cnpj: ''
      },
      itensPedido: params[:itens]
    }

    attempt.update(requisition: body)

    begin
      request = HTTParty.post(ENV.fetch('CORREIOS_CRIAR_PEDIDO'),
                              headers: authentication,
                              body: body.to_json)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if request['statusCode'].present?
      attempt_data = {
        status_code: request['statusCode'],
        message: request['mensagem'],
        exception: request['excecao'],
        classification: request['classificacao'],
        cause: request['causa'],
        url: request['url'],
        user: request['user']
      }
    end

    attempt_data[:status] = request['statusCode'] == 200 ? :success : :fail

    if request['mensagem'].present? && request['mensagem'].include?('Pedido já Cadastrado')
      match_data = request['mensagem'].match(/\(ID: (\d+)\)/)
      attempt_data[:status] = :success if match_data
      attempt_data[:order_correios_id] = match_data[1].to_i if match_data
    end

    attempt_data[:status] ||= :error
    attempt_data[:error] = 'Requisição vazia' unless request.present?

    attempt.update(attempt_data)
  end

  def self.get_tracking(order_correios_id)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg=='
    }
    begin
      HTTParty.get(ENV.fetch('CORREIOS_OBTER_PEDIDO') + order_correios_id, headers: authentication)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end
  end
end