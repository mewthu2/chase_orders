require 'test_helper'
require 'webmock/minitest'

class SyncB2bOrdersStatusJobTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @user = User.create!(name: 'Teste Sync', email: 'teste_sync@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Sync')
  end

  test 'updates the status of sale orders that already have a tiny_reference_id' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, status: :aberto, tiny_reference_id: '111')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'OK', pedido: { situacao: 'Faturado', codigo_rastreamento: 'BR1' } } }.to_json)

    SyncB2bOrdersStatusJob.perform_now

    order.reload
    assert order.faturado?
    assert_equal 'BR1', order.tracking_code
  end

  test 'ignores orders without a tiny_reference_id' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, status: :aberto)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    SyncB2bOrdersStatusJob.perform_now

    assert_not_requested :get, 'https://api.tiny.com.br/api2/pedido.obter.php'
    assert order.reload.aberto?
  end

  test 'ignores stock_transfer orders (they create a nota fiscal in Tiny, not a pedido)' do
    location = TransferLocation.create!(
      name: 'CD Sync', registration: '25.405.327/0001-74', street: 'Rua Sync',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
    order = B2bOrder.new(kind: :stock_transfer, user: @user, transfer_location: location, status: :aberto, tiny_reference_id: '222')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    SyncB2bOrdersStatusJob.perform_now

    assert_not_requested :get, 'https://api.tiny.com.br/api2/pedido.obter.php'
  end

  test 'also syncs B2C transfers (they are a pedido in Tiny)' do
    order = B2bOrder.new(kind: :b2c_transfer, user: @user, price_list: :transfer, status: :preparando_envio, tiny_reference_id: '333')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '333' }))
      .to_return(body: { retorno: { status: 'OK', pedido: { situacao: 'Enviado' } } }.to_json)

    SyncB2bOrdersStatusJob.perform_now

    assert order.reload.enviado?
  end
end
