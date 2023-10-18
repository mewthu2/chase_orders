class Correios::Orders
  def self.create_orders(params)
    authentication = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'Content-Type' => 'application/json',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
      'Cookie' => 'LBprdExt1=533331978.47873.0000; LBprdint3=1614413834.47873.0000'
    }

    body = {
      'codigoArmazem' => Env.fetch('CORREIOS_COD_ARMAZEM'),
      'numero' => params[:numero_ecommerce],
      'dataSolicitacao' => params[:data_pedido],
      'valordeclarado' => params[:valor],
      'cartaoPostagem' => Env.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoservico' => '39888',
      'numeroPLP' => '',
      'numeroSerie' => '1',
      'cnpjTransportadora' => Env.fetch('CORREIOS_CNPJ_TRANSPORTADORA'),
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
      'itensPedido' => params[:itens]
    }

    response = HTTParty.post(ENV.fetch('CORREIOS_CRIAR_PEDIDO'), headers: authentication, body: body.to_json)
  end
end