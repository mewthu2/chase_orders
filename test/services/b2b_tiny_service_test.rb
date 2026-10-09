require 'test_helper'
require 'webmock/minitest'

class B2bTinyServiceTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @service = B2bTinyService.new

    @user = User.create!(name: 'Teste Service', email: 'teste_service@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Service', registration: '25.405.327/0001-74')
    @location = TransferLocation.create!(
      name: 'CD Service', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
  end

  test 'shipping_methods parses the Tiny response into name/method pairs' do
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php').with(query: hash_including('formato' => 'json'))
      .to_return(body: {
        retorno: { status: 'OK', registros: [{ id: '782947860', nome: 'Transportadora', situacao: '1', tipo_logistica: '2' }] }
      }.to_json)

    result = @service.shipping_methods
    assert_equal [{ name: 'Transportadora', method: '782947860', logistics_type: '2' }], result
  end

  test 'shipping_methods returns empty array on Tiny error' do
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php').with(query: hash_including('formato' => 'json'))
      .to_return(body: { retorno: { status: 'Erro' } }.to_json)

    assert_equal [], @service.shipping_methods
  end

  test 'create_sale_order returns success with tiny reference on OK response' do
    stub_formas
    order = B2bOrder.new(kind: :sale, user: @user, client: @client,
                              carrier_name: 'Jamef', carrier_shipping_method: '782947860')
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10.5)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
    assert_equal '111', result[:tiny_reference_id]
    assert_equal '222', result[:tiny_reference_number]
  end

  test 'create_sale_order returns failure with the Tiny error message' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    result = @service.create_sale_order(order)
    refute result[:success]
    assert_equal 'CPF/CNPJ inválido', result[:error]
  end

  test 'create_stock_transfer returns success when status_processamento is 3' do
    order = B2bOrder.new(kind: :stock_transfer, user: @user, transfer_location: @location)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 5)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'OK', status_processamento: '3', registros: { registro: { numero: '999' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    assert result[:success]
    assert_equal '999', result[:tiny_reference_id]
  end

  test 'create_stock_transfer returns failure when Tiny rejects the note' do
    order = B2bOrder.new(kind: :stock_transfer, user: @user, transfer_location: @location)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 5)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', status_processamento: '1', registros: { registro: { erro: 'Item sem CFOP' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    refute result[:success]
    assert_equal 'Item sem CFOP', result[:error]
  end

  test 'create_sale_order sends the unit price net of the item discount' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10, discount: 2)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| URI.decode_www_form(req.body).to_h['pedido'].include?('"valor_unitario":8.0') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the standard natureza_operacao and no id_lista_preco for the standard price list' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, price_list: :standard)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with do |req|
        pedido = URI.decode_www_form(req.body).to_h['pedido']
        pedido.include?('"id_natureza_operacao":"898357546"') && !pedido.include?('id_lista_preco')
      end
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the transfer natureza_operacao and id_lista_preco for the transfer price list' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, price_list: :transfer)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with do |req|
        pedido = URI.decode_www_form(req.body).to_h['pedido']
        pedido.include?('"id_natureza_operacao":"790850411"') && pedido.include?('"id_lista_preco":"8198"')
      end
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order prefixes the observations with the salesperson name' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, salesperson_name: 'Fulano', notes: 'Entregar rápido')
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| URI.decode_www_form(req.body).to_h['pedido'].include?('"obs":"Vendedor: Fulano | Entregar rápido"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order includes endereco_entrega when the shipping address differs' do
    order = B2bOrder.new(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua Entrega', shipping_number: '50', shipping_neighbourhood: 'Bairro E',
      shipping_city: 'Rio de Janeiro', shipping_state: 'RJ', shipping_zip: '20000-000'
    )
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| URI.decode_www_form(req.body).to_h['pedido'].include?('"endereco_entrega"') && URI.decode_www_form(req.body).to_h['pedido'].include?('"cep":"20000-000"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the carrier name from the associated Carrier record' do
    carrier = Carrier.create!(
      name: 'Jamef Transportes', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
    stub_formas
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, carrier: carrier, carrier_shipping_method: '782947860')
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 10)
    order.save!

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| URI.decode_www_form(req.body).to_h['pedido'].include?('"nome_transportador":"Jamef Transportes"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'order_status returns the situacao and tracking code from Tiny' do
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'OK', pedido: { situacao: 'Faturado', codigo_rastreamento: 'BR123456789' } } }.to_json)

    result = @service.order_status('111')
    assert_equal 'Faturado', result[:situacao]
    assert_equal 'BR123456789', result[:tracking_code]
  end

  test 'order_status returns nil when Tiny responds with an error' do
    stub_request(:get, 'https://api.tiny.com.br/api2/pedido.obter.php')
      .with(query: hash_including({ 'id' => '111' }))
      .to_return(body: { retorno: { status: 'Erro' } }.to_json)

    assert_nil @service.order_status('111')
  end

  test 'update_order_status posts the mapped Tiny situacao for the order' do
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php')
           .with(body: hash_including('id' => '111', 'situacao' => 'pronto_envio'))
           .to_return(body: { retorno: { status: 'OK' } }.to_json)

    result = @service.update_order_status('111', 'pronto_para_envio')

    assert result[:success]
    assert_requested stub
  end

  test 'update_order_status returns the Tiny error message on failure' do
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.alterar.situacao.php')
      .to_return(body: { retorno: { status: 'Erro', erros: [{ erro: 'Situação inválida' }] } }.to_json)

    result = @service.update_order_status('111', 'cancelado')

    refute result[:success]
    assert_equal 'Situação inválida', result[:error]
  end

  def sale_order_for_errors
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10)
    order.save!
    order
  end

  def stub_pedido_response(retorno)
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php').to_return(body: { retorno: retorno }.to_json)
  end

  test 'create_sale_order surfaces the Tiny error found inside registros.registro.erros' do
    stub_pedido_response(status_processamento: '2', status: 'Erro', registros: {
      registro: { sequencia: '1', status: 'Erro', codigo_erro: '31', erros: [{ erro: 'Cliente: CPF/CNPJ inválido' }, { erro: 'Item LEG-838-M não encontrado' }] }
    })

    result = @service.create_sale_order(sale_order_for_errors)

    refute result[:success]
    assert_equal 'Cliente: CPF/CNPJ inválido, Item LEG-838-M não encontrado', result[:error]
  end

  test 'create_sale_order surfaces errors sent as an array of hashes at the top level' do
    stub_pedido_response(status_processamento: '1', status: 'Erro', codigo_erro: '20', erros: [{ erro: 'Token inválido' }])

    assert_equal 'Token inválido', @service.create_sale_order(sale_order_for_errors)[:error]
  end

  test 'create_sale_order still surfaces the legacy hash form of errors' do
    stub_pedido_response(status: 'Erro', erros: { erro: 'Pedido duplicado' })

    assert_equal 'Pedido duplicado', @service.create_sale_order(sale_order_for_errors)[:error]
  end

  test 'create_sale_order reports the status and error code when Tiny gives no message' do
    stub_pedido_response(status: 'Erro', codigo_erro: '99')

    error = @service.create_sale_order(sale_order_for_errors)[:error]

    assert_match(/Erro desconhecido na API Tiny/, error)
    assert_match(/status: Erro/, error)
    assert_match(/código: 99/, error)
  end

  test 'create_sale_order reports an HTML or empty response readably' do
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php').to_return(body: '<html>Bad gateway</html>', status: 502)

    error = @service.create_sale_order(sale_order_for_errors)[:error]

    assert_match(/resposta inválida do Tiny/i, error)
    assert_match(/502/, error)
  end

  # O Tiny só enxerga cliente e itens se o JSON vier embrulhado em {"pedido": {...}} (como no B2C).
  # Sem a raiz ele responde "O campo nome do cliente deve ser informado / É necessário informar ao menos um item".
  test 'create_sale_order sends the pedido wrapped in the "pedido" root with client and items inside it' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, salesperson_name: 'Fulano')
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10)
    order.b2b_order_items.build(sku: 'SKU2', name: 'Produto 2', quantity: 1, price: 5)
    order.save!
    sent = nil
    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| sent = JSON.parse(URI.decode_www_form(req.body).to_h['pedido']); true }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    @service.create_sale_order(order)

    assert sent.key?('pedido'), 'o JSON precisa ter a raiz "pedido"'
    assert_equal 1, sent.keys.size, 'nada fora da raiz'
    pedido = sent['pedido']
    assert_equal @client.display_name, pedido.dig('cliente', 'nome')
    assert_equal %w[SKU1 SKU2], pedido['itens'].map { |i| i.dig('item', 'codigo') }
    assert_equal 'preparando_envio', pedido['situacao']
  end

  test 'create_stock_transfer keeps sending the nota wrapped in the "nota_fiscal" root' do
    order = B2bOrder.new(kind: :stock_transfer, user: @user, transfer_location: @location)
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 5)
    order.save!
    sent = nil
    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .with { |req| sent = JSON.parse(URI.decode_www_form(req.body).to_h['nota']); true }
      .to_return(body: { retorno: { status_processamento: '3', status: 'OK', registros: { registro: { numero: '9' } } } }.to_json)

    @service.create_stock_transfer(order)

    assert_equal ['nota_fiscal'], sent.keys
    assert_equal @location.name, sent.dig('nota_fiscal', 'cliente', 'nome')
    assert_equal 1, sent.dig('nota_fiscal', 'itens').size
  end

  # ---- Forma de envio / frete: o Tiny guarda um código por tipo de logística e o serviço em forma_frete ----
  FORMAS_URL = 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php'.freeze
  CORREIOS_NAME = 'EMPRESA BRASILEIRA DE CORREIOS E TELEGRAFOS'.freeze

  def stub_formas
    stub_request(:get, FORMAS_URL).with(query: hash_including('formato' => 'json')).to_return(body: { retorno: { status: 'OK', registros: [
      { id: '782947858', nome: 'Correios', situacao: '1', tipo_logistica: '1' },
      { id: '782947860', nome: 'Transportadora', situacao: '1', tipo_logistica: '2' },
      { id: '782947861', nome: 'Retirar pessoalmente', situacao: '1', tipo_logistica: '6' },
      { id: '898469144', nome: 'Correios Log', situacao: '1', tipo_logistica: '5' },
      { id: '111', nome: 'Forma de tipo novo', situacao: '1', tipo_logistica: '9' }
    ] } }.to_json)
  end

  def send_sale(shipping = {})
    order = B2bOrder.new({ kind: :sale, user: @user, client: @client }.merge(shipping))
    order.b2b_order_items.build(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 10)
    order.save!
    sent = nil
    stub = stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
           .with { |req| sent = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido']; true }
           .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)
    result = @service.create_sale_order(order)
    [result, sent, stub]
  end

  test 'Correios Log is sent as forma_envio E with the chosen freight service and the Correios carrier' do
    stub_formas
    result, sent, = send_sale(carrier_shipping_method: '898469144', freight_service: 'PAC CORREIOS LOG+')

    assert result[:success]
    assert_equal 'E', sent['forma_envio']
    assert_equal 'PAC CORREIOS LOG+', sent['forma_frete']
    assert_equal CORREIOS_NAME, sent['nome_transportador']
    assert_equal 'D', sent['frete_por_conta']
    refute_includes sent.keys, 'id_forma_envio'
  end

  # Igual ao pedido 1859 (que passou pela criação dos Correios B2B): a fila exige forma_frete, e na
  # transportadora ele leva o nome dela.
  test 'a Transportadora is sent as forma_envio T with the carrier name as transporter and freight service' do
    stub_formas
    result, sent, = send_sale(carrier_shipping_method: '782947860', carrier_name: 'Mix Cargo')

    assert result[:success]
    assert_equal 'T', sent['forma_envio']
    assert_equal 'Mix Cargo', sent['nome_transportador']
    assert_equal 'Mix Cargo', sent['forma_frete']
  end

  test 'a Transportadora without a chosen carrier is refused before anything is sent to Tiny' do
    stub_formas
    result, sent, stub = send_sale(carrier_shipping_method: '782947860')

    refute result[:success]
    assert_match(/transportadora/i, result[:error])
    assert_not_requested stub
    assert_nil sent
  end

  test 'Correios is sent as forma_envio C and pickup as S' do
    stub_formas
    _, correios, = send_sale(carrier_shipping_method: '782947858')
    _, retirada, = send_sale(carrier_shipping_method: '782947861')

    assert_equal 'C', correios['forma_envio']
    assert_equal CORREIOS_NAME, correios['nome_transportador']
    assert_equal 'S', retirada['forma_envio']
  end

  test 'without a chosen shipping method no shipping fields are invented and Tiny is not asked for the list' do
    formas = stub_formas
    result, sent, = send_sale

    assert result[:success]
    assert_not_requested formas
    %w[forma_envio forma_frete nome_transportador].each { |key| refute_includes sent.keys, key }
  end

  test 'Correios Log without a freight service is refused before anything is sent to Tiny' do
    stub_formas
    result, sent, stub = send_sale(carrier_shipping_method: '898469144')

    refute result[:success]
    assert_match(/serviço de frete/i, result[:error])
    assert_not_requested stub
    assert_nil sent
  end

  test 'a shipping method Tiny does not list is refused instead of creating a badly configured order' do
    stub_formas
    result, _, stub = send_sale(carrier_shipping_method: '424242')

    refute result[:success]
    assert_match(/forma de envio.*não encontrada/i, result[:error])
    assert_not_requested stub
  end

  test 'a logistics type we do not map is refused with a clear message' do
    stub_formas
    result, _, stub = send_sale(carrier_shipping_method: '111')

    refute result[:success]
    assert_match(/Forma de tipo novo/, result[:error])
    assert_not_requested stub
  end

  test 'if the shipping methods cannot be read from Tiny the order is not sent' do
    stub_request(:get, FORMAS_URL).with(query: hash_including('formato' => 'json')).to_return(body: 'gateway', status: 502)
    result, _, stub = send_sale(carrier_shipping_method: '898469144', freight_service: 'PAC CORREIOS LOG+')

    refute result[:success]
    assert_match(/formas de envio/i, result[:error])
    assert_not_requested stub
  end
end
