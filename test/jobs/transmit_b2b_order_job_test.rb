require 'test_helper'
require 'webmock/minitest'

class TransmitB2bOrderJobTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste Transmit', email: 'teste_transmit@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Transmit')
  end

  test 'sets status to preparando_envio and stores the tiny reference on success' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.preparando_envio?
    assert_equal '111', order.tiny_reference_id
    assert_equal '222', order.tiny_reference_number
  end

  test 'sets status to dados_incompletos and stores the error message on failure' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)

    order.reload
    assert order.dados_incompletos?
    assert_equal 'CPF/CNPJ inválido', order.error_message
  end

  test 'does nothing when the order was already sent to Tiny (avoids duplicate orders from duplicate jobs)' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, status: :aprovado, tiny_reference_id: '111', tiny_reference_number: '222')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')

    TransmitB2bOrderJob.perform_now(order.id)

    assert_not_requested stub
    order.reload
    assert order.aprovado?, 'the status Tiny reported must not be reset'
    assert_equal '111', order.tiny_reference_id
  end

  test 'a cancelled order is not sent' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, status: :cancelado)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')

    TransmitB2bOrderJob.perform_now(order.id)

    assert_not_requested stub
    assert order.reload.cancelado?
  end

  test 'a second job for the same order right after the first does not send it again' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
           .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    TransmitB2bOrderJob.perform_now(order.id)
    TransmitB2bOrderJob.perform_now(order.id)

    assert_requested stub, times: 1
  end
end
