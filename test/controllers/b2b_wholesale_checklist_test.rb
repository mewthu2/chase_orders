require 'test_helper'
require 'webmock/minitest'

# Checklist do pedido do atacado: só clientes do Honey, SEDEX ou transportadora com frete digitado,
# forma de pagamento, desconto livre no total e sem desconto por item.
class B2bWholesaleChecklistTest < ActionDispatch::IntegrationTest
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze

  def setup
    @admin = User.create!(name: 'Admin Checklist', email: 'admin_checklist@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Loja Parceira', registration: '25.405.327/0001-74')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    sign_in @admin
  end

  def items = { '0' => { sku: 'SKU1', name: 'Produto', quantity: 2, price: 50 } }

  test 'the client search only looks in Honey' do
    get search_client_b2b_orders_path, params: { query: 'parceira' }

    clients = JSON.parse(response.body)['clients']
    assert_equal ['honey'], clients.map { |c| c['source'] }.uniq
    assert_not_requested :get, /api\.tiny\.com\.br/
    assert_not_requested :post, /api\.tiny\.com\.br/
  end

  test 'a wholesale order needs the payment method' do
    assert_no_difference('B2bOrder.count') do
      post b2b_orders_path, params: { b2b_order: { client_id: @client.id, b2b_order_items_attributes: items } }
    end
    assert_match 'Forma de pagamento', response.body

    post b2b_orders_path, params: { b2b_order: { client_id: @client.id, payment_method: 'boleto', order_discount: 10, order_discount_type: 'percent',
                                                 freight_value: 25, b2b_order_items_attributes: items } }
    order = B2bOrder.last
    assert_equal 'boleto', order.payment_method
    assert_equal 10, order.discount_amount
    assert_equal 25, order.freight_value
  end

  test 'sending to Tiny carries the payment, the discount in reais and the typed freight' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, payment_method: 'cartao', order_discount: 15, freight_value: 30)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 2, price: 50)
    order.save!
    pedido = nil
    stub_request(:post, PEDIDO_URL).with { |req| pedido = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido'] }
                                   .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '9', numero: '10' } } } }.to_json)

    post transmit_b2b_order_path(order)

    assert_nil pedido['forma_pagamento'], 'a forma de pagamento é só registro, não cobrança no Tiny'
    assert_nil pedido['meio_pagamento']
    assert_equal '15.00', pedido['valor_desconto']
    assert_equal 30.0, pedido['valor_frete']
    assert_includes pedido['obs'], 'Pagamento: Cartão'
  end

  test 'installments go to Tiny like Tiny ones: days, due date and value, adding up to the order total' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, payment_method: 'cartao', payment_terms: '30 60', freight_value: 20,
                         created_at: Time.zone.local(2026, 11, 12, 10))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 2, price: 50)
    order.save!
    pedido = nil
    stub_request(:post, PEDIDO_URL).with { |req| pedido = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido'] }
                                   .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '9', numero: '10' } } } }.to_json)

    post transmit_b2b_order_path(order)

    parcelas = pedido['parcelas'].map { |p| p['parcela'] }
    assert_equal [30, 60], parcelas.map { |p| p['dias'] }
    assert_equal %w[12/12/2026 11/01/2027], parcelas.map { |p| p['data'] }
    assert_equal %w[60.00 60.00], parcelas.map { |p| p['valor'] }
    assert_equal 'Cartão 1/2', parcelas.first['obs']
    assert_nil parcelas.first['forma_pagamento']
    assert_includes pedido['obs'], 'Pagamento: Cartão 2x (30 60)'
  end

  test 'a pix order goes without installments' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, payment_method: 'pix')
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 1, price: 50)
    order.save!
    pedido = nil
    stub_request(:post, PEDIDO_URL).with { |req| pedido = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido'] }
                                   .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '9', numero: '10' } } } }.to_json)

    post transmit_b2b_order_path(order)

    assert_nil pedido['parcelas']
  end

  test 'an old order without payment is not sent until someone picks it' do
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 1, price: 50)
    order.save!

    post transmit_b2b_order_path(order)

    assert_redirected_to edit_b2b_order_path(order)
    assert_not_requested :post, PEDIDO_URL
  end

  test 'the fixed freight comes from the setting: a new order starts with it and the value can be adjusted' do
    B2bSetting.current.update!(fixed_freight_value: 35)

    get new_b2b_order_path

    assert_select '#fixedFreightSelect option[selected]', text: 'Frete fixo (R$ 35,00)'
    assert_select 'input#freightValueField[value="35.0"]'
    assert_select '#freightChoiceSection[data-fixed-value="35.0"]'

    post b2b_orders_path, params: { b2b_order: { client_id: @client.id, payment_method: 'pix', fixed_freight: 'true', freight_value: 40, b2b_order_items_attributes: items } }
    assert B2bOrder.last.fixed_freight?
    assert_equal 40, B2bOrder.last.freight_value
  end

  test 'the fixed freight value is configured on its own screen' do
    get b2b_orders_path
    assert_select "a[href='#{edit_b2b_setting_path}']", text: /Configuração do atacado/

    get edit_b2b_setting_path
    assert_response :success
    patch b2b_setting_path, params: { b2b_setting: { fixed_freight_value: '42.50' } }

    assert_redirected_to b2b_orders_path
    assert_equal BigDecimal('42.50'), B2bSetting.current.fixed_freight_value
    patch b2b_setting_path, params: { b2b_setting: { fixed_freight_value: '-1' } }
    assert_response :unprocessable_entity
  end

  test 'the suggested wholesale price is retail minus 60% for Seamless and 56.60% for the rest, both configurable' do
    Product.create!(sku: 'SEAM-P', shopify_product_name: 'Legging Apex Seamless Ash', price: '100.00', image_url: 'https://img.example/a.jpg')
    Product.create!(sku: 'TOP-P', shopify_product_name: 'Top Signature Black', price: '100.00', image_url: 'https://img.example/b.jpg')

    get search_product_b2b_orders_path, params: { query: '-p' }
    prices = JSON.parse(response.body)['products'].to_h { |p| [p['sku'], p['suggested_price']] }
    assert_equal 40.0, prices['SEAM-P']
    assert_equal 43.4, prices['TOP-P']

    patch b2b_setting_path, params: { b2b_setting: { fixed_freight_value: 0, seamless_discount_percent: 50, default_discount_percent: 45 } }
    get search_product_b2b_orders_path, params: { query: '-p' }
    prices = JSON.parse(response.body)['products'].to_h { |p| [p['sku'], p['suggested_price']] }
    assert_equal 50.0, prices['SEAM-P']
    assert_equal 55.0, prices['TOP-P']
  end

  test 'the form has payment, freight value and the order discount, and no per-item discount' do
    get new_b2b_order_path

    assert_select 'select[name="b2b_order[payment_method]"] option', text: 'PIX'
    assert_select 'input[name="b2b_order[freight_value]"]'
    assert_select 'input[name="b2b_order[order_discount]"]'
    assert_select 'select[name="b2b_order[order_discount_type]"] option', text: '%'
    assert_select '#itemsTable th', text: 'Desconto', count: 0
    assert_select '#freightServiceSelect option', text: 'PAC CORREIOS LOG+', count: 0
    assert_select '#orderSummary'
    assert_select '#installmentsSection[style*="display: none"]'
    assert_select '#installmentsCountSelect option', count: B2bOrder::MAX_INSTALLMENTS
    assert_select 'input#paymentTermsField[name="b2b_order[payment_terms]"]'
  end
end
