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

  test 'index counts orders per status regardless of the active status filter' do
    sign_in @admin
    aberto = B2bOrder.create!(kind: :sale, user: @admin, client: @client, status: :aberto)
    aberto.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
    aprovado = B2bOrder.create!(kind: :sale, user: @admin, client: @client, status: :aprovado)
    aprovado.b2b_order_items.create!(sku: 'SKU2', quantity: 1, price: 1)

    get b2b_orders_path(status: 'aberto')

    # hrefs are unique per status (e.g. "status=aberto" vs "status=aprovado"),
    # so scoping the count assertion to each tab's own link avoids matching
    # the wrong tab's count pill.
    assert_select "a[href*='status=aberto']", text: /1/
    assert_select "a[href*='status=aprovado']", text: /1/
    assert_select 'tbody tr', count: 1
  end

  test 'index searches by client name' do
    sign_in @admin
    other_client = Client.create!(responsible_name: 'Outro Cliente Completamente Diferente')
    match = B2bOrder.create!(kind: :sale, user: @admin, client: @client)
    match.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)
    miss = B2bOrder.create!(kind: :sale, user: @admin, client: other_client)
    miss.b2b_order_items.create!(sku: 'SKU2', quantity: 1, price: 1)

    get b2b_orders_path(q: @client.responsible_name)

    assert_select 'tbody tr', count: 1
  end

  test 'admin can create a sale order with client and items, which auto-enqueues transmission' do
    sign_in @admin

    assert_enqueued_with(job: TransmitB2bOrderJob) do
      assert_difference 'B2bOrder.count', 1 do
        post b2b_orders_path, params: { b2b_order: {
          kind: 'sale', client_id: @client.id,
          b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
        } }
      end
    end
    order = B2bOrder.last
    assert order.aberto?
    assert_equal 1, order.b2b_order_items.count
  end

  test 'admin can create a sale order with the new form fields and a per-item discount' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', client_id: @client.id, salesperson_name: 'Fulano', price_list: 'transfer',
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10, discount: 1 }]
      } }
    end
    order = B2bOrder.last
    assert_equal 'Fulano', order.salesperson_name
    assert order.transfer?
    assert_equal 1.0, order.b2b_order_items.first.discount
  end

  test 'creating without items re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  test 'transmit resends only when the order is resendable' do
    sign_in @admin
    order = B2bOrder.new(kind: :sale, user: @admin, client: @client, status: :aberto, tiny_reference_id: '123')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    assert_no_enqueued_jobs only: TransmitB2bOrderJob do
      post transmit_b2b_order_path(order)
    end
    assert_redirected_to b2b_orders_path

    order.update!(status: :aberto, tiny_reference_id: nil)

    assert_enqueued_with(job: TransmitB2bOrderJob, args: [order.id]) do
      post transmit_b2b_order_path(order)
    end
  end

  def build_order(**attrs)
    order = B2bOrder.new({ kind: :sale, user: @admin, client: @client, status: :aberto }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  test 'update changes the status and pushes it to Tiny when the order was already transmitted' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php')
           .with(body: hash_including('id' => '111', 'situacao' => 'aprovado'))
           .to_return(body: { retorno: { status: 'OK' } }.to_json)

    patch b2b_order_path(order), params: { b2b_order: { status: 'aprovado' } }

    assert_requested stub
    assert_equal 'aprovado', order.reload.status
    assert_nil flash[:alert]
  end

  test 'update still saves the status but warns when Tiny rejects the change' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php')
      .to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Situação inválida' }] } }.to_json)

    patch b2b_order_path(order), params: { b2b_order: { status: 'cancelado' } }

    assert_equal 'cancelado', order.reload.status
    assert_match(/Situação inválida/, flash[:alert])
  end

  test 'update does not call Tiny when the order was never transmitted' do
    sign_in @admin
    order = build_order(status: :dados_incompletos)

    patch b2b_order_path(order), params: { b2b_order: { status: 'aprovado' } }

    assert_not_requested :post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php'
    assert_equal 'aprovado', order.reload.status
  end

  test 'update does not call Tiny when the status did not change' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')

    patch b2b_order_path(order), params: { b2b_order: { status: 'aberto', notes: 'x' } }

    assert_not_requested :post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php'
  end

  test 'search_product does not query Correios stock (only filled in once the item is added to the table)' do
    sign_in @admin
    Product.create!(sku: 'SKU-COR', shopify_product_name: 'Produto Correios')

    get search_product_b2b_orders_path, params: { query: 'SKU-COR' }
    json = JSON.parse(response.body)

    assert json['success']
    product_json = json['products'].first
    assert_equal 'SKU-COR', product_json['sku']
    refute product_json.key?('quantity')
    refute product_json.key?('status')
    assert_not_requested :get, 'https://correios-log.example.com/estoque/SKU-COR/estoque'
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

  test 'search_product also returns the plain retail price alongside the suggested one' do
    sign_in @admin
    Product.create!(sku: 'SKU-RET', shopify_product_name: 'Produto Retail', price: '100')

    get search_product_b2b_orders_path, params: { query: 'SKU-RET' }
    json = JSON.parse(response.body)

    product_json = json['products'].first
    assert_equal 100.0, product_json['retail_price']
    assert_equal 40.0, product_json['suggested_price']
  end

  test 'parse_items_spreadsheet also returns the plain retail price' do
    sign_in @admin
    Product.create!(sku: 'SKU-RET-CSV', shopify_product_name: 'Produto Retail CSV', price: '50')

    csv_content = "SKU,Quantidade\nSKU-RET-CSV,1\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert_equal 50.0, json['items'].first['retail_price']
  end

  test 'parse_items_spreadsheet does not query Correios stock (only filled in once the item is added to the table)' do
    sign_in @admin
    Product.create!(sku: 'SKU-CSV', shopify_product_name: 'Produto CSV')

    csv_content = "SKU,Quantidade\nSKU-CSV,2\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert json['success']
    item = json['items'].first
    assert_equal 'SKU-CSV', item['sku']
    assert_equal 2, item['quantity']
    refute item.key?('stock_quantity')
    refute item.key?('stock_status')
    assert_not_requested :get, 'https://correios-log.example.com/estoque/SKU-CSV/estoque'
  end
end
