require 'test_helper'
require 'webmock/minitest'

class B2bOrdersStockReservationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Reserva', email: 'admin_reserva@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Reserva', registration: '25.405.327/0001-74')
    Product.create!(sku: 'LEG-A', shopify_product_name: 'Legging A', image_url: 'https://img.example.com/a.png')

    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque')
      .to_return(status: 200, body: { disponivel: 3 }.to_json)
    StockReservation.create!(account: :b2b, tiny_order_id: '77', sku: 'LEG-A', quantity: 2)
    sign_in @admin
  end

  def order_params(quantity)
    { b2b_order: { client_id: @client.id, b2b_order_items_attributes: { '0' => { sku: 'LEG-A', name: 'Legging A', quantity: quantity, price: 10 } } } }
  end

  test 'product_stock returns stock, reserved and available' do
    get product_stock_b2b_orders_path, params: { sku: 'LEG-A' }
    json = JSON.parse(response.body)

    assert_equal [3, 2, 1, 'low'], json.values_at('stock', 'reserved', 'quantity', 'status')
  end

  test 'create is blocked when an item exceeds the available stock' do
    assert_no_difference('B2bOrder.count') { post b2b_orders_path, params: order_params(2) }

    assert_response :unprocessable_entity
    assert_match(/LEG-A: pedido 2, disponível 1/, response.body)
    assert_match(/2 reservados na fila/, response.body)
  end

  test 'update of an order not yet in Tiny is blocked too' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :aberto)
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 1, price: 10)
    order.save!
    item = order.b2b_order_items.first

    patch b2b_order_path(order), params: { b2b_order: { b2b_order_items_attributes: { '0' => { id: item.id, quantity: 5 } } } }

    assert_response :unprocessable_entity
    assert_equal 1, item.reload.quantity
  end

  test 'orders already in Tiny are not blocked by their own reservation' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 5, price: 10)
    order.save!

    patch b2b_order_path(order), params: { b2b_order: { notes: 'x' } }

    refute_equal 422, response.status
  end

  test 'transmit is blocked when an item exceeds the available stock' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :dados_incompletos)
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 3, price: 10)
    order.save!

    post transmit_b2b_order_path(order)

    assert_match(/disponível 1/, flash[:alert])
    assert_not_requested :post, 'https://api.tiny.com.br/api2/pedido.incluir.php'
  end

  test 'Correios being down does not block the order' do
    stub_request(:get, 'https://correios-log.example.com/estoque/LEG-A/estoque').to_return(status: 503)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    assert_difference('B2bOrder.count', 1) { post b2b_orders_path, params: order_params(50) }
  end

  test 'the order form shows when reservations were refreshed and when the next refresh happens' do
    StockReservationRefresh.for(:b2b).update!(status: 'success', last_refreshed_at: Time.zone.parse('2026-10-08 10:00'))

    get new_b2b_order_path

    assert_select '.reservation-freshness', text: /10:00/
    assert_select '.reservation-freshness', text: /10:10/
    assert_select 'th', text: /Estoque · Reservado · Disponível/
    assert_no_match(/só informativo/, response.body)
  end

  test 'the form enforces stock only while the order has not reached Tiny' do
    get new_b2b_order_path
    assert_select "#itemsTable[data-enforce-stock='true']"

    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 5, price: 10)
    order.save!
    get edit_b2b_order_path(order)
    assert_select "#itemsTable[data-enforce-stock='false']"
  end

  test 'product_stock does not count the reservation of the order being edited' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 2, price: 10)
    order.save!

    get product_stock_b2b_orders_path, params: { sku: 'LEG-A', b2b_order_id: order.id }
    json = JSON.parse(response.body)

    assert_equal [3, 0, 3], json.values_at('stock', 'reserved', 'quantity')
  end

  test 'the edit form asks the stock of its own order' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :preparando_envio, tiny_reference_id: '77')
    order.b2b_order_items.build(sku: 'LEG-A', quantity: 2, price: 10)
    order.save!

    get edit_b2b_order_path(order)

    assert_includes response.body, "product_stock?b2b_order_id=#{order.id}&sku="
  end
end
