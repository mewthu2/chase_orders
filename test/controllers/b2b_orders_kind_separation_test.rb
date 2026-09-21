require 'test_helper'
require 'webmock/minitest'

class B2bOrdersKindSeparationTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Sep', email: 'admin_sep@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente Separado', registration: '25.405.327/0001-74')
    @location = TransferLocation.create!(
      name: 'CD Separado', registration: '25.405.327/0001-74', street: 'Rua A',
      number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000'
    )
    sign_in @admin
  end

  def build_sale(**attrs)
    order = B2bOrder.new({ kind: :sale, user: @admin, client: @client }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  def build_transfer(**attrs)
    order = B2bOrder.new({ kind: :stock_transfer, user: @admin, transfer_location: @location, price_list: :transfer }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  test 'b2b_orders index lists only sale orders' do
    build_sale
    build_transfer

    get b2b_orders_path

    assert_select 'tbody tr', count: 1
    assert_select 'h1', /Atacado/
  end

  test 'stock_transfers index lists only stock transfers, without client or status tabs' do
    build_sale
    build_transfer

    get stock_transfers_path

    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /CD Separado/
    assert_select 'h1', /Transferências/
    assert_select '.status-tabs', count: 0
  end

  test 'sidebar links to both screens' do
    get b2b_orders_path

    assert_select "a[href='#{b2b_orders_path}']", text: /Pedidos de Atacado/
    assert_select "a[href='#{stock_transfers_path}']", text: /Transferências de Estoque/
  end

  test 'creating through stock_transfers forces the stock_transfer kind and returns to its list' do
    assert_enqueued_with(job: TransmitB2bOrderJob) do
      assert_difference 'B2bOrder.count', 1 do
        post stock_transfers_path, params: { b2b_order: {
          kind: 'sale', transfer_location_id: @location.id, price_list: 'transfer',
          b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
        } }
      end
    end

    assert B2bOrder.last.stock_transfer?
    assert_redirected_to stock_transfers_path
  end

  test 'creating through b2b_orders ignores a submitted stock_transfer kind' do
    post b2b_orders_path, params: { b2b_order: {
      kind: 'stock_transfer', client_id: @client.id,
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
    } }

    assert B2bOrder.last.sale?
    assert_redirected_to b2b_orders_path
  end

  test 'new stock transfer form has no kind select and posts the transfer price list' do
    get new_stock_transfer_path

    assert_response :success
    assert_select 'select#kindSelect', count: 0
    assert_select '#clientSection', count: 0
    assert_select '#transferLocationSection'
    assert_select 'input#priceListSelect[value=transfer]'
    assert_select "form[action='#{stock_transfers_path}']"
  end

  test 'new sale form has the client section and no transfer location' do
    get new_b2b_order_path

    assert_response :success
    assert_select 'select#kindSelect', count: 0
    assert_select '#clientSection'
    assert_select '#transferLocationSection', count: 0
  end

  test 'an order is only reachable through the screen of its own kind' do
    sale = build_sale
    transfer = build_transfer

    get edit_b2b_order_path(transfer)
    assert_response :not_found
    sign_in @admin # o 404 reinicia a sessão de teste do Devise
    get edit_stock_transfer_path(sale)
    assert_response :not_found
    sign_in @admin

    get edit_b2b_order_path(sale)
    assert_response :success
    get edit_stock_transfer_path(transfer)
    assert_response :success
  end

  test 'transmit is scoped to the kind of the screen' do
    transfer = build_transfer

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(transfer)
    end
    assert_response :not_found

    sign_in @admin # o 404 reinicia a sessão de teste do Devise
    assert_enqueued_with(job: TransmitB2bOrderJob, args: [transfer.id]) do
      post transmit_stock_transfer_path(transfer)
    end
    assert_redirected_to stock_transfers_path
  end

  test 'updating a stock transfer redirects to the transfers list' do
    transfer = build_transfer

    patch stock_transfer_path(transfer), params: { b2b_order: { notes: 'obs' } }

    assert_redirected_to stock_transfers_path
    assert_equal 'obs', transfer.reload.notes
  end
end
