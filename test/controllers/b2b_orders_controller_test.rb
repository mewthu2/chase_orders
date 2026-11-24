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
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
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
    build_order(status: :aberto)
    build_order(status: :aprovado)

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
    build_order
    build_order(client: other_client)

    get b2b_orders_path(q: @client.responsible_name)

    assert_select 'tbody tr', count: 1
  end

  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze

  def stub_tiny_pedido_ok(id: '111', numero: '222')
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: id, numero: numero } } } }.to_json)
  end

  def stub_tiny_pedido_error(message)
    stub_request(:post, PEDIDO_URL).to_return(body: { retorno: { status_processamento: '2', status: 'Erro', registros: { registro: { status: 'Erro', erros: [{ erro: message }] } } } }.to_json)
  end

  def create_sale_order
    post b2b_orders_path, params: { b2b_order: {
      kind: 'sale', payment_method: 'boleto', client_id: @client.id,
      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10 }]
    } }
    B2bOrder.last
  end

  test 'creating a sale order saves it only in Honey, without sending it to Tiny' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      create_sale_order
    end

    assert_not_requested :post, PEDIDO_URL
    order = B2bOrder.last
    assert order.aberto?
    assert_nil order.tiny_reference_id
    assert_equal 1, order.b2b_order_items.count
    assert_redirected_to b2b_orders_path
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /salvo.*Pedidos p\/ Aprovar/
  end

  test 'admin can create a sale order with the new form fields; a per-item discount sent anyway is ignored' do
    sign_in @admin

    assert_difference 'B2bOrder.count', 1 do
      post b2b_orders_path, params: { b2b_order: {
        kind: 'sale', payment_method: 'boleto', client_id: @client.id, salesperson_name: 'Fulano',
        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 2, price: 10, discount: 1 }]
      } }
    end
    order = B2bOrder.last
    assert_equal 'Fulano', order.salesperson_name
    assert order.standard?
    assert_equal 0.0, order.b2b_order_items.first.discount.to_f, 'não existe mais desconto manual por item'
  end

  test 'creating without items re-renders with errors' do
    sign_in @admin

    assert_no_difference 'B2bOrder.count' do
      post b2b_orders_path, params: { b2b_order: { kind: 'sale', payment_method: 'boleto', client_id: @client.id } }
    end
    assert_response :unprocessable_entity
  end

  def build_order(**attrs)
    order = B2bOrder.new({ kind: :sale, payment_method: 'boleto', user: @admin, client: @client, status: :aberto }.merge(attrs))
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!
    order
  end

  test 'the romaneio of an order with the order discount renders (no per-item discount column)' do
    sign_in @admin
    order = B2bOrder.new(kind: :sale, payment_method: 'boleto', user: @admin, client: @client, status: :aberto, order_discount: 5)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto', quantity: 2, price: 10)
    order.save!

    get romaneio_b2b_order_path(order)

    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  test 'romaneio downloads the order items as a PDF' do
    sign_in @admin
    order = build_order

    get romaneio_b2b_order_path(order)

    assert_response :success
    assert_equal 'application/pdf', response.media_type
    assert_match(/attachment; filename="romaneio-pedido-#{order.id}-cliente-b2b-test\.pdf"/, response.headers['Content-Disposition'])
    assert_includes response.body, '/Subtype /Image', 'o romaneio leva o logo da Chase'
    assert response.body.start_with?('%PDF')
  end

  test 'romaneio shows the product photos (thumbnail from the Shopify CDN) and still renders when a photo fails' do
    sign_in @admin
    png = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
    Product.create!(sku: 'SKU-FOTO', shopify_product_name: 'Com foto', image_url: 'https://cdn.shopify.com/s/files/foto.png?v=1')
    Product.create!(sku: 'SKU-QUEBRADA', shopify_product_name: 'Foto quebrada', image_url: 'https://img.example.com/quebrada.jpg')
    photo = stub_request(:get, 'https://cdn.shopify.com/s/files/foto.png?v=1&width=160').to_return(body: png)
    stub_request(:get, 'https://img.example.com/quebrada.jpg').to_return(status: 404)
    order = B2bOrder.new(kind: :sale, payment_method: 'boleto', user: @admin, client: @client, status: :aberto)
    order.b2b_order_items.build(sku: 'SKU-FOTO', name: 'Com foto', quantity: 1, price: 10)
    order.b2b_order_items.build(sku: 'SKU-QUEBRADA', name: 'Foto quebrada', quantity: 1, price: 10)
    order.save!

    get romaneio_b2b_order_path(order)

    assert_response :success
    assert_requested photo
    with_photo = response.body.scan('/Subtype /Image').size
    get romaneio_b2b_order_path(build_order)
    # A foto PNG com transparência vira imagem + máscara (2 objetos); a quebrada fica de fora.
    assert_equal response.body.scan('/Subtype /Image').size + 2, with_photo
  end

  test 'the sales list shows P / N next to the number, N colored by the order note' do
    sign_in @admin
    order = build_order
    company = Company.new(legal_name: 'Emissora', cnpj: '11.222.333/0001-81', street: 'R', number: '1', neighbourhood: 'B', city: 'BH',
                          city_ibge_code: '3106200', state: 'MG', zip: '30000000')
    company.save!(validate: false)
    FiscalNote.create!(company:, b2b_order: order, number: 21, series: 3, environment: :producao, status: :autorizada)
    other = build_order

    get b2b_orders_path

    assert_response :success
    assert_select "a.pg-pn[href='#{edit_b2b_order_path(order)}']", text: 'P'
    assert_select "a.pg-pn.is-ok[href='#{edit_b2b_order_path(order, tab: 'nota')}'][data-tip*='nº 21']", text: 'N'
    assert_select "a.pg-pn.is-none[href='#{edit_b2b_order_path(other, tab: 'nota')}']", text: 'N'
  end

  test 'the sales list shows the total with the freight and the payment method' do
    sign_in @admin
    order = B2bOrder.new(kind: :sale, payment_method: 'pix', user: @admin, client: @client, status: :aberto, freight_value: 25)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 2, price: 50)
    order.save!

    get b2b_orders_path

    assert_select 'thead th', text: 'Total com frete'
    assert_select 'thead th', text: 'Pagamento'
    assert_select 'tbody td', text: /R\$\s*125,00/
    assert_select 'tbody', text: /com R\$ 25,00 de frete/
    assert_select 'tbody td', text: 'PIX'
  end

  test 'romaneio is only served on the screen of the order kind' do
    sign_in @admin
    order = build_order

    get romaneio_b2c_transfer_path(order)

    assert_response :not_found
  end

  test 'update changes the status only in Honey, even for an old order sent to Tiny (the Tiny 2 is no longer used)' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')

    patch b2b_order_path(order), params: { b2b_order: { status: 'aprovado' } }

    assert_not_requested :post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php'
    assert_equal 'aprovado', order.reload.status
    assert_nil flash[:alert]
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

  test 'update deletes an item removed from the table (sent with _destroy)' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')
    kept = order.b2b_order_items.first
    removed = order.b2b_order_items.create!(sku: 'SKU2', quantity: 1, price: 1)

    patch b2b_order_path(order), params: { b2b_order: { b2b_order_items_attributes: {
      '0' => { id: kept.id, sku: 'SKU1', quantity: 1, price: 1 },
      '1' => { id: removed.id, _destroy: '1' }
    } } }

    assert_equal ['SKU1'], order.reload.b2b_order_items.map(&:sku)
  end

  test 'update does not delete the last item of the order' do
    sign_in @admin
    order = build_order(tiny_reference_id: '111')

    patch b2b_order_path(order), params: { b2b_order: { b2b_order_items_attributes: {
      '0' => { id: order.b2b_order_items.first.id, _destroy: '1' }
    } } }

    assert_response :unprocessable_entity
    assert_equal 1, order.reload.b2b_order_items.count
  end

  test 'search_product does not query Correios stock (only filled in once the item is added to the table)' do
    sign_in @admin
    Product.create!(sku: 'SKU-COR', shopify_product_name: 'Produto Correios', image_url: 'https://img.example.com/produto.png')

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
    Product.create!(sku: 'SKU-COR2', shopify_product_name: 'Produto Correios 2', image_url: 'https://img.example.com/produto.png')

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
    Product.create!(sku: 'SKU-RET', shopify_product_name: 'Produto Retail', price: '100', image_url: 'https://img.example.com/produto.png')

    get search_product_b2b_orders_path, params: { query: 'SKU-RET' }
    json = JSON.parse(response.body)

    product_json = json['products'].first
    assert_equal 100.0, product_json['retail_price']
    assert_equal 43.4, product_json['suggested_price'] # 56,60% de desconto (não é Seamless)
  end

  test 'search_product and product_picker return the B2C transfer price as 70% of cost' do
    sign_in @admin
    Product.create!(sku: 'SKU-B2C', shopify_product_name: 'Produto B2C', price: '100', cost: '50', image_url: 'https://img.example.com/produto.png')

    get search_product_b2b_orders_path, params: { query: 'SKU-B2C' }
    assert_equal 35.0, JSON.parse(response.body)['products'].first['b2c_transfer_price']

    get product_picker_b2b_orders_path, params: { query: 'SKU-B2C' }
    assert_equal 35.0, JSON.parse(response.body)['products'].first['variants'].first['b2c_transfer_price']
  end

  test 'parse_items_spreadsheet returns the B2C transfer price, nil when the product has no cost' do
    sign_in @admin
    Product.create!(sku: 'SKU-B2C-CSV', shopify_product_name: 'Produto B2C CSV', price: '80', cost: '20.10', image_url: 'https://img.example.com/produto.png')
    Product.create!(sku: 'SKU-NO-COST', shopify_product_name: 'Sem custo', price: '80', image_url: 'https://img.example.com/produto.png')

    csv_content = "SKU,Quantidade\nSKU-B2C-CSV,1\nSKU-NO-COST,1\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    items = JSON.parse(response.body)['items']

    assert_equal 14.07, items.first['b2c_transfer_price']
    assert_nil items.last['b2c_transfer_price']
  end

  test 'parse_items_spreadsheet also returns the plain retail price' do
    sign_in @admin
    Product.create!(sku: 'SKU-RET-CSV', shopify_product_name: 'Produto Retail CSV', price: '50', image_url: 'https://img.example.com/produto.png')

    csv_content = "SKU,Quantidade\nSKU-RET-CSV,1\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert_equal 50.0, json['items'].first['retail_price']
  end

  test 'parse_items_spreadsheet accepts semicolon-separated CSV saved by Excel' do
    sign_in @admin
    Product.create!(sku: 'SKU-SEMI', shopify_product_name: 'Produto Ponto e Virgula', price: '50', image_url: 'https://img.example.com/produto.png')

    csv_content = "\uFEFFSKU;Quantidade\r\nSKU-SEMI;10\r\n"
    file = Rack::Test::UploadedFile.new(StringIO.new(csv_content), 'text/csv', original_filename: 'items.csv')

    post parse_items_spreadsheet_b2b_orders_path, params: { file: file }
    json = JSON.parse(response.body)

    assert json['success']
    assert_equal 'SKU-SEMI', json['items'].first['sku']
    assert_equal 'Produto Ponto e Virgula', json['items'].first['name']
    assert_equal 10, json['items'].first['quantity']
  end

  test 'parse_items_spreadsheet does not query Correios stock (only filled in once the item is added to the table)' do
    sign_in @admin
    Product.create!(sku: 'SKU-CSV', shopify_product_name: 'Produto CSV', image_url: 'https://img.example.com/produto.png')

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
  INVOICE_URL = 'https://api.tiny.com.br/api2/gerar.nota.fiscal.pedido.php'.freeze

end
