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
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php')
      .to_return(body: {
        retorno: { status: 'OK', registros: [{ id: '782947860', nome: 'Transportadora', situacao: '1', tipo_logistica: '2' }] }
      }.to_json)

    result = @service.shipping_methods
    assert_equal [{ name: 'Transportadora', method: '782947860' }], result
  end

  test 'shipping_methods returns empty array on Tiny error' do
    stub_request(:get, 'https://api.tiny.com.br/api2/formas.envio.pesquisa.php')
      .to_return(body: { retorno: { status: 'Erro' } }.to_json)

    assert_equal [], @service.shipping_methods
  end

  test 'create_sale_order returns success with tiny reference on OK response' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client,
                              carrier_name: 'Jamef', carrier_shipping_method: 'jamef')
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10.5)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '111', numero: '222' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
    assert_equal '111', result[:tiny_reference_id]
    assert_equal '222', result[:tiny_reference_number]
  end

  test 'create_sale_order returns failure with the Tiny error message' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    result = @service.create_sale_order(order)
    refute result[:success]
    assert_equal 'CPF/CNPJ inválido', result[:error]
  end

  test 'create_stock_transfer returns success when status_processamento is 3' do
    order = B2bOrder.create!(kind: :stock_transfer, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'OK', status_processamento: '3', registros: { registro: { numero: '999' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    assert result[:success]
    assert_equal '999', result[:tiny_reference_id]
  end

  test 'create_stock_transfer returns failure when Tiny rejects the note' do
    order = B2bOrder.create!(kind: :stock_transfer, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', status_processamento: '1', registros: { registro: { erro: 'Item sem CFOP' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    refute result[:success]
    assert_equal 'Item sem CFOP', result[:error]
  end

  test 'create_sale_order sends the unit price net of the item discount' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 2, price: 10, discount: 2)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"valor_unitario":8.0') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the standard natureza_operacao and no id_lista_preco for the standard price list' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, price_list: :standard)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with do |req|
        pedido = JSON.parse(req.body)['pedido']
        pedido.include?('"id_natureza_operacao":"898357546"') && !pedido.include?('id_lista_preco')
      end
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the transfer natureza_operacao and id_lista_preco for the transfer price list' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, price_list: :transfer)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with do |req|
        pedido = JSON.parse(req.body)['pedido']
        pedido.include?('"id_natureza_operacao":"790850411"') && pedido.include?('"id_lista_preco":"8198"')
      end
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order prefixes the observations with the salesperson name' do
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, salesperson_name: 'Fulano', notes: 'Entregar rápido')
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"obs":"Vendedor: Fulano | Entregar rápido"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order includes endereco_entrega when the shipping address differs' do
    order = B2bOrder.create!(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua Entrega', shipping_number: '50', shipping_neighbourhood: 'Bairro E',
      shipping_city: 'Rio de Janeiro', shipping_state: 'RJ', shipping_zip: '20000-000'
    )
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"endereco_entrega"') && JSON.parse(req.body)['pedido'].include?('"cep":"20000-000"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_sale_order sends the carrier name from the associated Carrier record' do
    carrier = Carrier.create!(
      name: 'Jamef Transportes', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )
    order = B2bOrder.create!(kind: :sale, user: @user, client: @client, carrier: carrier)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 10)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .with { |req| JSON.parse(req.body)['pedido'].include?('"nome_transportador":"Jamef Transportes"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '1', numero: '2' } } } }.to_json)

    result = @service.create_sale_order(order)
    assert result[:success]
  end

  test 'create_carrier_contact returns the Tiny contact id on success' do
    carrier = Carrier.create!(
      name: 'Jamef Transportes', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )

    stub_request(:post, 'https://api.tiny.com.br/api2/contato.incluir.php')
      .with { |req| body = JSON.parse(req.body)['contato']; body.include?('"nome":"Jamef Transportes"') && body.include?('"tipo":"Transportadora"') }
      .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '555' } } } }.to_json)

    result = @service.create_carrier_contact(carrier)
    assert result[:success]
    assert_equal '555', result[:tiny_contact_id]
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

  test 'create_carrier_contact returns the Tiny error message on failure' do
    carrier = Carrier.create!(
      name: 'Jamef Transportes', registration: '25.405.327/0001-74', street: 'Rua Service',
      number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000'
    )

    stub_request(:post, 'https://api.tiny.com.br/api2/contato.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CNPJ já cadastrado' } } }.to_json)

    result = @service.create_carrier_contact(carrier)
    refute result[:success]
    assert_equal 'CNPJ já cadastrado', result[:error]
  end
end
