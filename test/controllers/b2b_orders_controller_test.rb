require 'test_helper'
require 'webmock/minitest'

class B2bOrdersControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin B2B', email: 'admin_b2b@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Cliente B2B Test', registration: '25.405.327/0001-74')

    ENV['CORREIOS_ESTOQUE'] = 'https://correios-log.example.com/estoque/'
    ENV['CORREIOS_CARTAO_POSTAGEM_2'] = 'fake-cartao-2'
    ENV['TOKEN_LOG_PRODUCTION2'] = 'fake-token-2'
  end

  test 'user without b2b_orders access is redirected' do
    profile = Profile.create!(name: 'Sem Acesso B2B')
    user = User.create!(name: 'Sem Acesso B2B', email: 'sem_acesso_b2b@example.com', password: 'password123')
    user.profiles << profile
    sign_in user

    get b2b_orders_path
    assert_redirected_to root_path
  end

  test 'admin can create a draft without items or client' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'draft' } }
    end
    assert_redirected_to b2b_orders_path
  end

  test 'admin can create a saved sale order with client and items' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', status: 'saved', client_id: @client.id,
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
      } }
    end
    order = B2bOrder.last
    assert order.saved?
    assert_equal 1, order.b2b_order_items.count
  end

  test 'saving without items when not draft re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', status: 'saved', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  test 'transmit enqueues the job only when transmittable' do
    sign_in @admin
    order = B2bOrder.create!(kind: :sale, status: :draft, user: @admin, client: @client)

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(order)
    end
    assert_redirected_to b2b_orders_path

    order.update!(status: :saved)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    assert_enqueued_with(job: TransmitB2bOrderJob, args: [order.id]) do
      post transmit_b2b_order_path(order)
    end
  end

  test 'search_product returns stock from the Correios API' do
    sign_in @admin
    Product.create!(sku: 'SKU-COR', shopify_product_name: 'Produto Correios')

    stub_request(:get, 'https://correios-log.example.com/estoque/SKU-COR/estoque')
      .to_return(status: 200, body: { disponivel: 25 }.to_json)

    get search_product_b2b_orders_path, params: { query: 'SKU-COR' }
    json = JSON.parse(response.body)

    assert json['success']
    product_json = json['products'].first
    assert_equal 25, product_json['quantity']
    assert_equal 'high', product_json['status']
  end

  test 'product_stock returns stock from the Correios API for a known SKU' do
    sign_in @admin
    Product.create!(sku: 'SKU-COR2', shopify_product_name: 'Produto Correios 2')

    stub_request(:get, 'https://correios-log.example.com/estoque/SKU-COR2/estoque')
      .to_return(status: 200, body: { disponivel: 3 }.to_json)

    get product_stock_b2b_orders_path, params: { sku: 'SKU-COR2' }
    json = JSON.parse(response.body)

    assert json['success']
    assert_equal 3, json['quantity']
    assert_equal 'low', json['status']
  end

  test 'product_stock returns an error when the SKU is unknown' do
    sign_in @admin

    get product_stock_b2b_orders_path, params: { sku: 'DOES-NOT-EXIST' }
    json = JSON.parse(response.body)

    assert json['success']
    assert_equal 0, json['quantity']
    assert_equal 'error', json['status']
  end

  test 'parse_items_spreadsheet includes Correios stock for each parsed item' do
    sign_in @admin
    Product.create!(sku: 'SKU-CSV', shopify_product_name: 'Produto CSV')

    stub_request(:get, 'https://correios-log.example.com/estoque/SKU-CSV/estoque')
      .to_return(status: 200, body: { disponivel: 0 }.to_json)

    csv_content = "SKU,Quantidade\nSKU-CSV,2\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert json['success']
    item = json['items'].first
    assert_equal 'SKU-CSV', item['sku']
    assert_equal 2, item['quantity']
    assert_equal 0, item['stock_quantity']
    assert_equal 'out', item['stock_status']
  end
end
