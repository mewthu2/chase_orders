class Correios::Orders
  def self.create_orders(params, attempt)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg=='
    }
    body = {
      'codigoArmazem' => ENV.fetch('CORREIOS_COD_ARMAZEM'),
      'numero' => params[:numero_ecommerce],
      'dataSolicitacao' => params[:data_pedido],
      'valordeclarado' => params[:valor],
      'cartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoservico' => '39888',
      'numeroPLP' => '',
      'numeroSerie' => '1',
      'cnpjTransportadora' => ENV.fetch('CORREIOS_CNPJ_TRANSPORTADORA'),
      'servicosAdicionais' => ['019'],
      'destinatario' => {
        'nome' => params[:valor],
        'logradouro' => params[:endereco],
        'numeroEndereco' => params[:numero],
        'complemento' => params[:complemento],
        'bairro' => params[:bairro],
        'cep' => params[:cep],
        'cidade' => params[:cidade],
        'uf' => params[:uf],
        'ddd' => params[:fone].match(/\(([^)]+)\)/)[1],
        'telefone' => params[:fone].scan(/[^()]+/).last.strip,
        'email' => params[:email],
        'cpf' => params[:cpf_cnpj],
        'cnpj' => ''
      },
      'itensPedido' => params[:itens].first
    }
    attempt.update(requisition: body)
    begin
      request = HTTParty.post(ENV.fetch('CORREIOS_CRIAR_PEDIDO'), headers: authentication, body: body.to_json)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if request.present?
      attempt.update(status_code: request['statusCode'],
                     message: request['mensagem'],
                     exception: request['excecao'],
                     classification: request['classificacao'],
                     cause: request['causa'],
                     url: request['url'],
                     user: request['user'])
      if request['statusCode'] == 200
        attempt.update(status: :success)
      else
        attempt.update(status: :fail)
      end
    else
      attempt.update(status: :error, error: 'Requisição vazia')
    end
  end
end