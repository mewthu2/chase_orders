require 'test_helper'
require 'webmock/minitest'

class B2cTransfersTest < ActionDispatch::IntegrationTest
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze

  def setup
    @admin = User.create!(name: 'Admin B2C', email: 'admin_b2c@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente B2C', registration: '25.405.327/0001-74')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    sign_in @admin
  end

  def build_b2c(**attrs)
    order = B2bOrder.new({ kind: :b2c_transfer, user: @admin, price_list: :transfer,
                           carrier_shipping_method: '782947860', carrier_name: 'Mix Cargo' }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  INVOICE_URL = 'https://api.tiny.com.br/api2/gerar.nota.fiscal.pedido.php'.freeze

  def stub_invoice_ok
    stub_request(:post, INVOICE_URL).with(body: hash_including('id' => '902371809'))
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { idNotaFiscal: '44', serie: '1', numero: '000321' } } } }.to_json)
  end

  def stub_pedido_ok
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '902371809', numero: '1859' } } } }.to_json)
  end

  test 'the Pedidos B2B menu links to the B2C transfer screen' do
    get b2b_orders_path

    assert_select "#pedidosB2bDropdown a[href='#{b2c_transfers_path}']", text: /Transferência B2B → B2C/
    assert_select "#produtosDropdown a[href='#{b2c_transfers_path}']", count: 0
  end

  test 'creating forces the b2c_transfer kind and transfer list, and lands in preparando_envio' do
    stub = stub_pedido_ok
    stub_invoice_ok
    assert_difference 'B2bOrder.count', 1 do
      post b2c_transfers_path, params: { b2b_order: {
        kind: 'sale', client_id: @client.id, price_list: 'standard',
        carrier_shipping_method: '782947860', carrier_name: 'Mix Cargo',
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
      } }
    end

    assert_requested stub
    order = B2bOrder.last
    assert order.b2c_transfer?
    assert order.transfer?
    assert_nil order.client
    assert order.preparando_envio?
    assert_equal '1859', order.tiny_reference_number
    assert_redirected_to b2c_transfers_path
    assert_match(/Transferência B2C/, flash[:notice])
  end

  test 'the index lists only B2C transfers with the fixed destination' do
    build_b2c
    sale = B2bOrder.new(kind: :sale, user: @admin, client: @client)
    sale.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    sale.save!

    get b2c_transfers_path

    assert_response :success
    assert_select 'h1', /Transferência B2B → B2C/
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /CHASE BRASIL/
  end

  test 'the form has no client nor transfer location and uses the transfer price list' do
    get new_b2c_transfer_path

    assert_response :success
    assert_select '#clientSection', count: 0
    assert_select '#transferLocationSection', count: 0
    assert_select '#b2cDestinationSection', text: /25.405.327\/0003-36/
    assert_select '#shippingMethodSelect', count: 0
    assert_select '#carrierSection', count: 0
    assert_select '.hand-delivery-badge', text: /Transportadora/
    assert_select 'input[name=generate_invoice]', count: 0
    assert_match(/var PRICE_LIST = 'transfer'/, response.body)
    assert_select "form[action='#{b2c_transfers_path}']"
  end

  test 'a B2C transfer is only reachable through its own screen' do
    order = build_b2c

    get edit_b2b_order_path(order)
    assert_response :not_found
    sign_in @admin

    get edit_b2c_transfer_path(order)
    assert_response :success
    assert_select "form[action='#{b2c_transfer_path(order)}']"
  end

  test 'cancel in Tiny works for a sent B2C transfer' do
    order = build_b2c(tiny_reference_id: '902371809', tiny_reference_number: '1859', status: :preparando_envio)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php')
      .to_return(body: { retorno: { status: 'OK' } }.to_json)

    post cancel_in_tiny_b2c_transfer_path(order)

    assert_redirected_to b2c_transfers_path
    assert_nil order.reload.tiny_reference_id
  end

  test 'creating ignores shipping data: a B2C transfer is hand delivery' do
    stub_pedido_ok
    stub_invoice_ok

    post b2c_transfers_path, params: { b2b_order: {
      carrier_shipping_method: '782947860', carrier_name: 'Mix Cargo',
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
    } }

    order = B2bOrder.last
    assert order.b2c_transfer?
    assert_nil order.carrier_shipping_method
    assert_nil order.carrier_name
    assert order.preparando_envio?
  end

  test 'creating always generates the nota fiscal of the transfer in Tiny' do
    stub_pedido_ok
    invoice = stub_invoice_ok

    post b2c_transfers_path, params: { b2b_order: { b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }] } }

    assert_requested invoice
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /enviado ao Tiny.*Nota fiscal gerada no Tiny \(nº 000321\)/
  end

  test 'when Tiny does not generate the nota the transfer stays sent and the error is shown' do
    stub_pedido_ok
    stub_request(:post, INVOICE_URL).to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Sem regra fiscal' }] } }.to_json)

    post b2c_transfers_path, params: { b2b_order: { b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }] } }

    assert_equal '902371809', B2bOrder.last.tiny_reference_id
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /não gerou a nota fiscal: Sem regra fiscal/
  end

  test 'the edit page has no nota checkbox: resending a B2C transfer always generates it' do
    order = build_b2c

    get edit_b2c_transfer_path(order)

    assert_select "form[action='#{transmit_b2c_transfer_path(order)}']", count: 1
    assert_select 'input[name=generate_invoice]', count: 0
    assert_select 'select[name="b2b_order[status]"]'
  end
end
