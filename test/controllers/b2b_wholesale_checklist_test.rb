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

  def seed_rates
    B2bFreightRate.delete_all
    B2bFreightRate.create!(min_value: 0, max_value: 5000, price: 300)
    B2bFreightRate.create!(min_value: 5000.01, max_value: 10_000, price: 336.84)
  end

  test 'the table freight follows the order value and "Outro valor" keeps the typed value' do
    seed_rates

    get new_b2b_order_path
    assert_select '#fixedFreightSelect option[selected]', text: 'Frete da tabela (pelo valor do pedido)'
    assert_select 'input#freightValueField[value="300.0"]'
    assert_select '#shippingModeSelect option', text: 'Correios Log'
    assert_select '#shippingModeSelect option', text: 'Transportadora'
    assert_select '#shippingModeSelect option', text: 'Retirada'
    assert_select '#shippingModeSelect option', count: 4

    big = { '0' => { sku: 'SKU1', name: 'Produto', quantity: 60, price: 100 } }
    post b2b_orders_path, params: { b2b_order: { client_id: @client.id, payment_method: 'pix', fixed_freight: 'true', freight_value: 1, b2b_order_items_attributes: big } }
    assert_equal BigDecimal('336.84'), B2bOrder.last.freight_value

    post b2b_orders_path, params: { b2b_order: { client_id: @client.id, payment_method: 'pix', fixed_freight: 'false', freight_value: 40, b2b_order_items_attributes: items } }
    assert_equal 40, B2bOrder.last.freight_value
  end

  test 'pickup has no freight, no carrier and no freight service' do
    seed_rates
    carrier = Carrier.create!(name: 'Transp', registration: '11.222.333/0001-81', street: 'Rua', number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')

    post b2b_orders_path, params: { b2b_order: { client_id: @client.id, payment_method: 'pix', pickup: 'true', fixed_freight: 'true', carrier_id: carrier.id,
                                                 freight_service: 'SEDEX CORREIOS LOG+', freight_value: 99, b2b_order_items_attributes: items } }
    order = B2bOrder.last
    assert order.pickup?
    assert_equal 0, order.freight_value
    assert_nil order.carrier_id
    assert_nil order.freight_service
    assert_equal 'Retirada', order.shipping_label
  end

  test 'the freight table has its own screen' do
    seed_rates
    get b2b_freight_rates_path
    assert_response :success
    assert_match 'R$336,84', response.body.delete(' ')

    post b2b_freight_rates_path, params: { b2b_freight_rate: { min_value: 10_000.01, max_value: 15_000, price: 373.68 } }
    assert_redirected_to b2b_freight_rates_path
    assert_equal BigDecimal('373.68'), B2bFreightRate.price_for(12_000)
    assert_equal BigDecimal('373.68'), B2bFreightRate.price_for(500_000)

    assert_no_difference('B2bFreightRate.count') do
      post b2b_freight_rates_path, params: { b2b_freight_rate: { min_value: 4000, max_value: 6000, price: 1 } }
    end
    assert_response :unprocessable_entity

    rate = B2bFreightRate.ordered.last
    patch b2b_freight_rate_path(rate), params: { b2b_freight_rate: { price: 400 } }
    assert_equal 400, rate.reload.price
    delete b2b_freight_rate_path(rate)
    assert_not B2bFreightRate.exists?(rate.id)
  end

  test 'the settings screen links to the freight table' do
    get b2b_orders_path
    assert_select "a[href='#{edit_b2b_setting_path}']", text: /Configuração do atacado/

    get edit_b2b_setting_path
    assert_response :success
    assert_select "a[href='#{b2b_freight_rates_path}']"
  end

  test 'the suggested wholesale price is retail minus 60% for Seamless and 56.60% for the rest, both configurable' do
    Product.create!(sku: 'SEAM-P', shopify_product_name: 'Legging Apex Seamless Ash', price: '100.00', image_url: 'https://img.example/a.jpg')
    Product.create!(sku: 'TOP-P', shopify_product_name: 'Top Signature Black', price: '100.00', image_url: 'https://img.example/b.jpg')

    get search_product_b2b_orders_path, params: { query: '-p' }
    prices = JSON.parse(response.body)['products'].to_h { |p| [p['sku'], p['suggested_price']] }
    assert_equal 40.0, prices['SEAM-P']
    assert_equal 43.4, prices['TOP-P']

    patch b2b_setting_path, params: { b2b_setting: { seamless_discount_percent: 50, default_discount_percent: 45 } }
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
