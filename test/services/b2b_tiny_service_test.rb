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
    order = B2bOrder.create!(kind: :sale, status: :saved, user: @user, client: @client,
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
    order = B2bOrder.create!(kind: :sale, status: :saved, user: @user, client: @client)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 1)

    stub_request(:post, 'https://api.tiny.com.br/api2/pedido.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', erros: { erro: 'CPF/CNPJ inválido' } } }.to_json)

    result = @service.create_sale_order(order)
    refute result[:success]
    assert_equal 'CPF/CNPJ inválido', result[:error]
  end

  test 'create_stock_transfer returns success when status_processamento is 3' do
    order = B2bOrder.create!(kind: :stock_transfer, status: :saved, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', name: 'Produto 1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'OK', status_processamento: '3', registros: { registro: { numero: '999' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    assert result[:success]
    assert_equal '999', result[:tiny_reference_id]
  end

  test 'create_stock_transfer returns failure when Tiny rejects the note' do
    order = B2bOrder.create!(kind: :stock_transfer, status: :saved, user: @user, transfer_location: @location)
    order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 5)

    stub_request(:post, 'https://api.tiny.com.br/api2/nota.fiscal.incluir.php')
      .to_return(body: { retorno: { status: 'Erro', status_processamento: '1', registros: { registro: { erro: 'Item sem CFOP' } } } }.to_json)

    result = @service.create_stock_transfer(order)
    refute result[:success]
    assert_equal 'Item sem CFOP', result[:error]
  end
end
