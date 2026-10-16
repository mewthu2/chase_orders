require 'test_helper'
require 'webmock/minitest'

class Correios::InvoicesTest < ActiveSupport::TestCase
  XML_URL = 'https://correios.example.com/enviar-xml'.freeze
  ORDER_URL = 'https://correios.example.com/pedidos/'.freeze

  def setup
    ENV['CORREIOS_ENVIAR_XML'] = XML_URL
    ENV['CORREIOS_OBTER_PEDIDO'] = ORDER_URL
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = '0080275680'
    ENV['CORREIOS_COD_ARMAZEM'] = '00425002'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'user:pass'
    stub_request(:get, "#{ORDER_URL}25141650").to_return(body: { rastreio: [] }.to_json)
    @attempt = Attempt.create!(kinds: :send_xml_tiny2, tiny_order_id: 902_483_374, order_correios_id: 25_141_650, xml_nota: '<nfe/>')
  end

  test 'an empty answer keeps the HTTP code in the message' do
    stub_request(:post, XML_URL).to_return(status: 502, body: '')

    Correios::Invoices.send_xml_to_correios(@attempt)

    assert @attempt.reload.error?
    assert_equal '502', @attempt.status_code
    assert_match(/Requisição vazia.*HTTP 502/, @attempt.message)
  end

  test 'an unexpected code with a body is recorded instead of leaving the attempt without status' do
    stub_request(:post, XML_URL).to_return(status: 500, body: 'Erro interno')

    Correios::Invoices.send_xml_to_correios(@attempt)

    assert @attempt.reload.error?
    assert_match(/HTTP 500: Erro interno/, @attempt.message)
  end

  test 'a network failure is recorded with its error' do
    stub_request(:post, XML_URL).to_timeout

    Correios::Invoices.send_xml_to_correios(@attempt)

    assert @attempt.reload.error?
    assert_match(/Falha ao enviar o XML/, @attempt.message)
    assert @attempt.error.present?
  end
end
