class Correios::Orders
  def self.create_orders(params)
    url = 'https://cws.correios.com.br/efulfillment/v1/pedidos'

    headers = {
      'numeroCartaoPostagem' => '0074549596',
      'Content-Type' => 'application/json',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
      'Cookie' => 'LBprdExt1=533331978.47873.0000; LBprdint3=1614413834.47873.0000'
    }

    body = {
      'codigoArmazem' => '00425002',
      'numero' => '11125',
      'dataSolicitacao' => '05/10/2023 07:27:33',
      'valordeclarado' => '809,70',
      'cartaoPostagem' => '0074549596',
      'codigoservico' => '39888',
      'numeroPLP' => '',
      'numeroSerie' => '1',
      'cnpjTransportadora' => '34028316000103',
      'servicosAdicionais' => ['019'],
      'destinatario' => {
        'nome' => 'Loja Belvedere',
        'logradouro' => 'Rua Juvenal Melo Senra',
        'numeroEndereco' => '355',
        'complemento' => 'Loja Chase',
        'bairro' => 'Belvedere',
        'cep' => '30320660',
        'cidade' => 'Belo Horizonte',
        'uf' => 'MG',
        'ddd' => '31',
        'telefone' => '93618-2221',
        'email' => 'danielkbr89@gmail.com',
        'cpf' => '09053481680',
        'cnpj' => ''
      },
      'itensPedido' => [
        {
          'codigo' => 'SHO-143-P',
          'quantidade' => '1'
        },
        {
          'codigo' => 'LEG-141-P',
          'quantidade' => '1'
        },
        {
          'codigo' => 'TOP-145-P',
          'quantidade' => '1'
        }
      ]
    }

    response = HTTParty.post(url, headers: headers, body: body.to_json)
  end
end