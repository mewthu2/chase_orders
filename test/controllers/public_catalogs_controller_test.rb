require 'test_helper'

class PublicCatalogsControllerTest < ActionDispatch::IntegrationTest
  def setup
    user = User.create!(name: 'Dono', email: 'dono_publico@example.com', password: 'password123')
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', image_url: 'https://img/a.jpg')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M')
    @catalog = B2bCatalog.create!(title: 'Coleção Verão', notes: 'Até sexta', user: user,
                                  products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @p, @m = @catalog.variants.to_a
    @p.update!(available: 3, availability: :low)
    @m.update!(available: 0, availability: :sold_out)
    @client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
  end

  def submit(catalog = @catalog, **body)
    post public_catalog_submit_path(catalog.public_token), params: body, as: :json
    JSON.parse(response.body)
  end

  test 'shows the catalog without login, with levels and without prices or exact stock' do
    get public_catalog_path(@catalog.public_token)

    assert_response :success
    assert_select 'h1', text: /Coleção Verão/
    assert_select "img.pc-logo[alt='Chase']"
    payload = JSON.parse(css_select('#catalogData').first.text)
    variant = payload['styles'].first['colors'].first['variants'].first
    assert_equal 'low', variant['availability']
    refute_match(/preço|R\$/i, response.body)
  end

  test 'unknown token is a 404' do
    get public_catalog_path('nope')
    assert_response :not_found
  end

  test 'a general catalog order needs name and a valid CNPJ' do
    json = submit(customer_name: 'Loja', customer_registration: '25.405.327/0001-75', quantities: { @p.id => 1 })
    refute json['ok']
    assert_match(/CNPJ inválido/, json['error'])
  end

  test 'submitting creates the order, sets the cookie and the same CNPJ updates it' do
    json = submit(customer_name: 'Loja Centro', customer_registration: '25.405.327/0001-74', quantities: { @p.id => 2 })

    assert json['ok']
    order = @catalog.catalog_orders.last
    assert_equal [[@p.id, 2]], order.items.pluck(:b2b_catalog_variant_id, :quantity)
    assert order.pending?
    assert_equal 'customer', order.last_edited_by
    assert cookies["catalog_order_#{@catalog.id}"].present?

    order.update!(status: :seen)
    assert_no_difference('B2bCatalogOrder.count') do
      submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 3 })
    end
    assert_equal 3, order.items.reload.first.quantity
    assert order.reload.pending?
  end

  test 'quantities above available or from another catalog are refused' do
    assert_match(/acima do disponível/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 4 })['error'])
    assert_match(/acima do disponível/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @m.id => 1 })['error'])
    assert_match(/fora deste catálogo/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { 999_999 => 1 })['error'])
    assert_match(/pelo menos uma peça/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 0 })['error'])
    assert_equal 0, B2bCatalogOrder.count
  end

  test 'a closed catalog or a converted order cannot be changed' do
    submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 1 })
    @catalog.catalog_orders.last.update!(status: :converted)
    assert_match(/em andamento/, submit(customer_name: 'L', customer_registration: '25405327000174', quantities: { @p.id => 2 })['error'])

    @catalog.update!(status: :closed)
    assert_match(/encerrado/, submit(customer_name: 'Outra', customer_registration: '11.222.333/0001-81', quantities: { @p.id => 1 })['error'])
    get public_catalog_path(@catalog.public_token)
    assert_select '.pc-closed', text: /encerrado/i
  end

  test 'identify by CNPJ loads the existing order' do
    submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 2 })
    cookies.delete("catalog_order_#{@catalog.id}")

    post public_catalog_identify_path(@catalog.public_token), params: { customer_registration: '25.405.327/0001-74' }, as: :json
    json = JSON.parse(response.body)

    assert json['ok']
    assert_equal 'Loja Centro', json['order']['customer_name']
    assert_equal({ @p.id.to_s => 2 }, json['order']['quantities'])
  end

  test 'the cookie reopens the order on the next visit' do
    submit(customer_name: 'Loja Centro', customer_registration: '25405327000174', quantities: { @p.id => 2 })

    get public_catalog_path(@catalog.public_token)
    payload = JSON.parse(css_select('#catalogData').first.text)

    assert_equal 'Loja Centro', payload['order']['customer_name']
    assert_equal({ @p.id.to_s => 2 }, payload['order']['quantities'])
  end

  test 'a client catalog needs no identification and keeps a single order' do
    catalog = B2bCatalog.create!(title: 'Só Loja Centro', kind: :client, client: @client, user: @catalog.user,
                                 products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P] }])
    variant = catalog.variants.first
    variant.update!(available: 10, availability: :available)

    get public_catalog_path(catalog.public_token)
    payload = JSON.parse(css_select('#catalogData').first.text)
    assert_equal 'Loja Centro', payload['order']['customer_name']
    refute payload['catalog']['needs_identification']

    assert submit(catalog, quantities: { variant.id => 4 })['ok']
    assert submit(catalog, quantities: { variant.id => 5 })['ok']
    assert_equal 1, catalog.catalog_orders.count
    assert_equal @client, catalog.catalog_orders.first.client
  end
end
