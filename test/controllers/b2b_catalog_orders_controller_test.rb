require 'test_helper'
require 'webmock/minitest'

class B2bCatalogOrdersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Ana Admin', email: 'ana_catalog_orders@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    Product.create!(sku: 'A-P', shopify_product_name: 'Top A Black', option1: 'P', price: '100')
    Product.create!(sku: 'A-M', shopify_product_name: 'Top A Black', option1: 'M', price: '100')
    @catalog = B2bCatalog.create!(title: 'Geral', user: @admin, products_attributes: [{ style_name: 'Top A', color_name: 'Black', skus: %w[A-P A-M] }])
    @p, @m = @catalog.variants.to_a
    @client = Client.create!(responsible_name: 'Loja Centro', registration: '25.405.327/0001-74')
    @order = @catalog.catalog_orders.create!(customer_name: 'Loja Centro', customer_registration: '25405327000174')
    @order.replace_items!({ @p.id => 2, @m.id => 3 }, edited_by: 'customer')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    sign_in @admin
  end

  test 'opening a new order marks it as seen and shows its items' do
    get b2b_catalog_catalog_order_path(@catalog, @order)

    assert_response :success
    assert @order.reload.seen?
    assert_select '.catalog-order-item', count: 2
    assert_select '.catalog-order-item', text: /Top A.*Black.*P.*2/m
  end

  test 'Honey can change the order and it records who changed it' do
    patch b2b_catalog_catalog_order_path(@catalog, @order), params: { quantities: { @p.id.to_s => '5', @m.id.to_s => '0' } }

    assert_redirected_to b2b_catalog_catalog_order_path(@catalog, @order)
    assert_equal [[@p.id, 5]], @order.items.reload.pluck(:b2b_catalog_variant_id, :quantity)
    assert_equal 'Ana Admin', @order.reload.last_edited_by
  end

  test 'a converted order cannot be edited' do
    @order.update!(status: :converted)

    patch b2b_catalog_catalog_order_path(@catalog, @order), params: { quantities: { @p.id.to_s => '9' } }

    assert_match(/já virou pedido/, flash[:alert])
    assert_equal 2, @order.items.find_by(b2b_catalog_variant_id: @p.id).quantity
  end

  test 'create order opens the B2B order form filled with the items and the matching client' do
    get new_b2b_order_path(catalog_order_id: @order.id)

    assert_response :success
    assert_select "input[name$='[sku]'][value='A-P']"
    assert_select "input[name$='[quantity]'][value='3']"
    assert_select "input[name$='[price]'][value='40.0']"
    assert_select "#clientIdField[value='#{@client.id}']"
    assert_select "input[name='catalog_order_id'][value='#{@order.id}']"
  end

  test 'saving the B2B order converts the catalog order' do
    stub_request(:get, %r{formas\.envio}).to_return(body: { retorno: { status: 'OK', registros: [] } }.to_json)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    assert_difference('B2bOrder.count', 1) do
      post b2b_orders_path, params: { catalog_order_id: @order.id, b2b_order: { client_id: @client.id, b2b_order_items_attributes: {
        '0' => { sku: 'A-P', name: 'Top A Black - P', quantity: 2, price: 40 }
      } } }
    end

    assert @order.reload.converted?
    assert_equal B2bOrder.last, @order.b2b_order
  end
end
