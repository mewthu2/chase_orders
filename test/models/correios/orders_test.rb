require 'test_helper'
require 'webmock/minitest'

class Correios::OrdersTest < ActiveSupport::TestCase
  def setup
    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM'] = 'cartao-b2c'
    ENV['TOKEN_LOG_PRODUCTION'] = 'token-b2c'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'cartao-b2b'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'token-b2b'
  end

  test 'get_stock authenticates with the B2C card and token by default' do
    stub_request(:get, 'https://correios-log.example.com/estoque/SKU1/estoque')
      .with(headers: {
        'numeroCartaoPostagem' => 'cartao-b2c',
        'Authorization' => "Basic #{Base64.strict_encode64('token-b2c')}"
      })
      .to_return(status: 200, body: { disponivel: 10 }.to_json)

    response = Correios::Orders.get_stock('SKU1')
    assert_equal 200, response.code
  end

  test 'get_stock authenticates with the B2B card and token when from_tiny2 is true' do
    stub_request(:get, 'https://correios-log.example.com/estoque/SKU1/estoque')
      .with(headers: {
        'numeroCartaoPostagem' => 'cartao-b2b',
        'Authorization' => "Basic #{Base64.strict_encode64('token-b2b')}"
      })
      .to_return(status: 200, body: { disponivel: 10 }.to_json)

    response = Correios::Orders.get_stock('SKU1', from_tiny2: true)
    assert_equal 200, response.code
  end

  def build_params(numero)
    {
      invoice: '919929089', numero_ecommerce: '69349', data_pedido: '19/09/2026', valor: '50.00',
      nome: 'Adriana Braul Romano', endereco: 'Avenida Manoel Casanova', numero: numero,
      complemento: 'Parque Santa Rosa, Suzano', bairro: 'Parque Santa Rosa', cep: '08664000',
      cidade: 'Suzano', uf: 'SP', fone: '11942457648', email: 'a@example.com',
      cpf_cnpj: '14365897896', pedido_id: '919929089', forma_envio: '39888',
      itens: [{ codigo: 'LEG-1659-M', quantidade: '1' }]
    }
  end

  def body_sent_for(params)
    ENV['CORREIOS_COD_ARMAZEM'] = '1'
    ENV['CORREIOS_CNPJ_TRANSPORTADORA'] = '123'
    ENV['CORREIOS_CRIAR_PEDIDO'] = 'https://correios-log.example.com/pedidos'

    sent = nil
    stub_request(:post, 'https://correios-log.example.com/pedidos').to_return do |request|
      sent = JSON.parse(request.body)
      { status: 400, body: 'x' }
    end

    Correios::Orders.create_orders(params, Attempt.create!(kinds: :create_correios_order_tiny2, tiny_order_id: 919_929_089))
    sent
  end

  test 'hand delivery goes as an additional service on top of the SEDEX service' do
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'card2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'token2'
    body = body_sent_for(build_params('1').merge(mao_propria: true))

    assert_equal '39888', body['codigoservico']
    assert_equal %w[019 002], body['servicosAdicionais']
  end

  test 'orders without hand delivery keep only the declared value additional service' do
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'card2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'token2'
    body = body_sent_for(build_params('1'))

    assert_equal %w[019], body['servicosAdicionais']
  end

  def destinatario_sent_for(numero, **options)
    ENV['CORREIOS_COD_ARMAZEM'] = '1'
    ENV['CORREIOS_CNPJ_TRANSPORTADORA'] = '123'
    ENV['CORREIOS_CRIAR_PEDIDO'] = 'https://correios-log.example.com/pedidos'

    sent = nil
    stub_request(:post, 'https://correios-log.example.com/pedidos').to_return do |request|
      sent = JSON.parse(request.body)
      { status: 400, body: 'x' }
    end

    attempt = Attempt.create!(kinds: :create_correios_order, tiny_order_id: 919_929_089)
    Correios::Orders.create_orders(build_params(numero), attempt, **options)
    sent['destinatario']
  end

  def numero_endereco_sent_for(numero)
    destinatario_sent_for(numero)['numeroEndereco']
  end

  test 'create_orders sends the client name as recipient by default' do
    assert_equal 'Adriana Braul Romano', destinatario_sent_for('1')['nome']
  end

  test 'create_orders replaces the recipient name when recipient_name is given' do
    assert_equal 'TRANSFERENCIA B2B PARA B2C', destinatario_sent_for('1', recipient_name: 'TRANSFERENCIA B2B PARA B2C')['nome']
  end

  test 'create_orders keeps only digits of numero when text is mixed in' do
    assert_equal '1360', numero_endereco_sent_for('1360 parque santa')
  end

  test 'create_orders limits numero to 6 digits' do
    assert_equal '123456', numero_endereco_sent_for('123456789')
  end

  test 'create_orders falls back to S/N when numero has no digits' do
    assert_equal 'S/N', numero_endereco_sent_for('s/n')
    assert_equal 'S/N', numero_endereco_sent_for('')
  end
end
