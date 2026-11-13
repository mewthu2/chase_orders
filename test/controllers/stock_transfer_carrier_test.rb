require 'test_helper'
require 'webmock/minitest'

# Abastecimento das lojas: SEDEX com mão própria (padrão) ou por transportadora.
class StockTransferCarrierTest < ActionDispatch::IntegrationTest
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze
  INVOICE_URL = 'https://api.tiny.com.br/api2/gerar.nota.fiscal.pedido.php'.freeze

  def setup
    @admin = User.create!(name: 'Admin Abast', email: 'admin_abast@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @location = TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0001-74', street: 'Rua A',
                                         number: '10', neighbourhood: 'Bairro', city: 'BH', state: 'MG', zip: '30000-000')
    @carrier = Carrier.create!(name: 'MIX CARGO TRANSPORTES', registration: '11.222.333/0001-81', street: 'Rua T',
                               number: '1', neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    @pedido = nil
    stub_request(:post, PEDIDO_URL).with { |req| @pedido = JSON.parse(URI.decode_www_form(req.body).to_h['pedido'])['pedido'] }
                                   .to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '90000777', numero: '777' } } } }.to_json)
    stub_request(:post, INVOICE_URL).to_return(body: { retorno: { status: 'OK', registros: { registro: { id: '5', numero: '42' } } } }.to_json)
    sign_in @admin
  end

  def items = [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }]

  test 'the form offers both deliveries and the list shows how each one goes' do
    get new_stock_transfer_path
    assert_select 'input[name=stock_delivery][value=hand][checked]'
    assert_select 'input[name=stock_delivery][value=carrier]'
    assert_select "select#stockCarrierSelect option[value='#{@carrier.id}']", text: 'MIX CARGO TRANSPORTES'
    assert_select '#itemsTable th', text: 'Desconto', count: 0

    post stock_transfers_path, params: { b2b_order: { transfer_location_id: @location.id, carrier_id: @carrier.id, b2b_order_items_attributes: items } }
    get stock_transfers_path
    assert_match 'Transportadora · MIX CARGO TRANSPORTES', response.body
  end

  test 'the Correios B2B classification still sees a carrier supply as store supply' do
    assert_equal :store_supply, B2bOrderType.classify(cnpj: @location.registration, notes: 'Abastecimento Loja #1')
  end
end
