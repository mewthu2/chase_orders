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
end
