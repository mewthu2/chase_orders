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
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    sign_in @admin
  end

  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze
  INVOICE_URL = 'https://api.tiny.com.br/api2/gerar.nota.fiscal.pedido.php'.freeze

  # Abastecimento vira pedido no Tiny e já sai com a nota fiscal gerada.
  def stub_tiny_nota_ok(numero: '777')
    stub_request(:post, INVOICE_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '5', numero: '42' } } } }.to_json)
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '90000777', numero: numero } } } }.to_json)
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
    assert_select 'h1', /Abastecimento/
    assert_select '.status-tabs', count: 0
  end

  test 'sidebar links to both screens' do
    get b2b_orders_path

    assert_select "a[href='#{b2b_orders_path}']", text: /Pedidos de Atacado/
    assert_select "a[href='#{stock_transfers_path}']", text: /Abastecimento Lojas/
  end

  test 'creating through stock_transfers forces the stock_transfer kind and returns to its list' do
    stub = stub_tiny_nota_ok
    assert_no_enqueued_jobs do
      assert_difference 'B2bOrder.count', 1 do
        post stock_transfers_path, params: { b2b_order: {
          kind: 'sale', transfer_location_id: @location.id, price_list: 'transfer',
          b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
        } }
      end
    end

    assert_requested stub
    assert B2bOrder.last.stock_transfer?
    assert_equal '777', B2bOrder.last.tiny_reference_number
    assert_redirected_to stock_transfers_path
  end

  test 'creating through b2b_orders ignores a submitted stock_transfer kind' do
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)
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
    assert_select 'input[name="b2b_order[price_list]"]', count: 0
    assert_match(/var PRICE_LIST = 'transfer'/, response.body)
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

    nota = stub_tiny_nota_ok
    post transmit_b2b_order_path(transfer)
    assert_response :not_found
    assert_not_requested nota

    sign_in @admin # o 404 reinicia a sessão de teste do Devise
    post transmit_stock_transfer_path(transfer)
    assert_requested nota
    assert_equal '777', transfer.reload.tiny_reference_number
    assert_redirected_to stock_transfers_path
  end

  test 'updating a stock transfer redirects to the transfers list' do
    transfer = build_transfer

    patch stock_transfer_path(transfer), params: { b2b_order: { notes: 'obs' } }

    assert_redirected_to stock_transfers_path
    assert_equal 'obs', transfer.reload.notes
  end

  test 'the wholesale form has no price list field: it is always the standard list' do
    get new_b2b_order_path

    assert_select 'select[name="b2b_order[price_list]"]', count: 0
    assert_select 'input[name="b2b_order[price_list]"]', count: 0
    assert_select '#priceListSelect', count: 0
    assert_match(/var PRICE_LIST = 'standard'/, response.body)
    assert_no_match(/Lista de preço/, response.body)
  end

  test 'a wholesale order is created with the standard price list even if transfer is submitted' do
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)
    post b2b_orders_path, params: { b2b_order: {
      client_id: @client.id, price_list: 'transfer',
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]
    } }

    assert B2bOrder.last.sale?
    assert B2bOrder.last.standard?
  end

  test 'a stock transfer is created with the transfer price list even if standard is submitted' do
    stub_tiny_nota_ok
    post stock_transfers_path, params: { b2b_order: {
      transfer_location_id: @location.id, price_list: 'standard',
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]
    } }

    assert B2bOrder.last.stock_transfer?
    assert B2bOrder.last.transfer?
  end

  test 'editing a wholesale order cannot switch it to the transfer price list' do
    sale = build_sale

    patch b2b_order_path(sale), params: { b2b_order: { price_list: 'transfer', notes: 'obs' } }

    assert_equal 'obs', sale.reload.notes
    assert sale.standard?
  end

  test 'the transfer edit form keeps the transfer price list and cannot change it either' do
    transfer = build_transfer

    patch stock_transfer_path(transfer), params: { b2b_order: { price_list: 'standard', notes: 'obs' } }

    assert_equal 'obs', transfer.reload.notes
    assert transfer.transfer?
  end

  test 'the wholesale form has the freight service select for Correios Log and the transfer form does not need it' do
    get new_b2b_order_path

    assert_select 'select#freightServiceSelect[name="b2b_order[freight_service]"] option', count: 4 # em branco + 3 serviços
    assert_select 'select#freightServiceSelect option', text: 'PAC CORREIOS LOG+'
    assert_select '#freightServiceSection'
    assert_match(/logistics_type|logistics/, response.body)
  end

  test 'the freight service is saved with the wholesale order' do
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php').with(query: hash_including('formato' => 'json'))
      .to_return(body: { retorno: { status: 'OK', registros: [{ id: '898469144', nome: 'Correios Log', situacao: '1', tipo_logistica: '5' }] } }.to_json)

    post b2b_orders_path, params: { b2b_order: {
      client_id: @client.id, carrier_shipping_method: '898469144', freight_service: 'SEDEX CORREIOS LOG+',
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]
    } }

    order = B2bOrder.last
    assert_equal 'SEDEX CORREIOS LOG+', order.freight_service
    assert order.aberto?, order.error_message
  end

  test 'a stock transfer enters Tiny as a pedido in preparando envio, with the nota generated' do
    stub_tiny_nota_ok(numero: '1900')
    post stock_transfers_path, params: { b2b_order: {
      transfer_location_id: @location.id, carrier_shipping_method: '123', freight_service: 'PAC CORREIOS LOG+',
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]
    } }

    order = B2bOrder.last
    assert order.preparando_envio?
    assert_equal '90000777', order.tiny_reference_id
    assert_nil order.freight_service, 'abastecimento é sempre SEDEX, não aceita outro serviço'
    assert_requested :post, INVOICE_URL
    follow_redirect!
    assert_select '.flash-messages-container', text: /Nota fiscal gerada no Tiny/
  end

  test 'the stock transfers list has no romaneio and links the Tiny number to the pedido' do
    transfer = build_transfer(tiny_reference_id: '90000777', tiny_reference_number: '1900', status: :preparando_envio)

    get stock_transfers_path

    assert_select "a[href*='romaneio']", count: 0
    assert_select "a[href='https://erp.tiny.com.br/vendas#edit/90000777']"
    get edit_stock_transfer_path(transfer)
    assert_select "a[href*='romaneio']", count: 0
    assert_select '#shippingMethodSelect', count: 0
    assert_match(/SEDEX · Mão Própria/, response.body)
  end

  test 'an old stock transfer that became a nota fiscal still links to the nota' do
    build_transfer(tiny_reference_id: '777', tiny_reference_number: '777')

    get stock_transfers_path

    assert_select "a[href='https://erp.tiny.com.br/notas_fiscais#edit/777']"
  end
end
