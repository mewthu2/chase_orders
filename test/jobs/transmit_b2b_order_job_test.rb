require 'test_helper'
require 'webmock/minitest'

class TransmitB2bOrderJobTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste Transmit', email: 'teste_transmit@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Transmit')
  end

  test 'sets status to aberto and stores the tiny reference on success' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.aberto?
    assert_equal '111', order.tiny_reference_id
    assert_equal '222', order.tiny_reference_number
  end

  test 'sets status to dados_incompletos and stores the error message on failure' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.dados_incompletos?
    assert_equal 'CPF/CNPJ inválido', order.error_message
  end
end
