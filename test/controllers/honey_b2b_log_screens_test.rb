require 'test_helper'
require 'webmock/minitest'

# Telas do Log02 com os pedidos feitos no Honey (sem Tiny) e os formulários dos pedidos B2B.
class HoneyB2bLogScreensTest < ActionDispatch::IntegrationTest
  PEDIDO_URL = 'https://api.tiny.com.br/api2/pedido.incluir.php'.freeze

  def setup
    @admin = User.create!(name: 'Admin Log Honey', email: 'admin_log_honey@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Lojista', business_name: 'Loja Parceira Ltda', registration: '45.723.174/0001-10')
    @location = TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0004-17', street: 'Rua A', number: '10',
                                         neighbourhood: 'Centro', city: 'BH', state: 'MG', zip: '30000-000')
    @carrier = Carrier.create!(name: 'MIX CARGO', registration: '34.028.316/0001-03', street: 'Rua T', number: '1',
                               neighbourhood: 'B', city: 'BH', state: 'MG', zip: '30000-000')
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token-tiny2'
    stub_request(:get, /api\.tiny\.com\.br/).to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)
    @tiny = stub_request(:post, PEDIDO_URL)
    sign_in @admin
  end

  def sale(**attrs)
    o = B2bOrder.new({ kind: :sale, user: @admin, client: @client, payment_method: 'pix', freight_service: 'SEDEX CORREIOS LOG+' }.merge(attrs))
    o.b2b_order_items.build(sku: 'SKU1', name: 'Legging', quantity: 2, price: 50)
    o.save!
    o
  end

  test 'Honey orders show up to be approved; approving sends them to the creation step, ignoring takes them out' do
    o = sale

    get order_correios_create_b2b_dashboard_index_path
    assert_select '#pgt-honey tbody tr', text: /##{o.id}.*Loja Parceira Ltda/m

    post approve_honey_order_b2b_dashboard_index_path(id: o.id)
    o.reload
    assert o.aprovado?
    assert_equal 'creation', o.log_stage

    post ignore_honey_order_b2b_dashboard_index_path(id: o.id)
    assert o.reload.log_ignored?
    assert_equal 'ignored', o.log_stage
  end

  test 'every Log02 screen lists the Honey orders of its step' do
    sale(status: :aprovado)
    sale(status: :preparando_envio, correios_order_id: 9)
    [order_correios_create_queue_b2b_dashboard_index_path, send_xml_b2b_dashboard_index_path, push_tracking_b2b_dashboard_index_path,
     order_correios_tracking_b2b_dashboard_index_path].each do |path|
      get path
      assert_response :success, path
      assert_select '#pgt-honey', 1, path
    end
  end

  test 'the edit page has no Send to Tiny anymore, only the Pedido and Nota fiscal tabs' do
    o = sale

    get edit_b2b_order_path(o)

    assert_no_match(/Enviar ao Tiny|Gerar nota fiscal no Tiny/, response.body)
    assert_select '.it-tabs [data-it-tab=nota]', text: /Nota fiscal/
    # Sem empresa emissora configurada, a aba avisa e leva à Configuração do atacado.
    assert_select '[data-it-panel=nota] .it-fiscal-card', text: /Escolha a empresa emissora/
    assert_select "[data-it-panel=nota] a[href='#{edit_b2b_setting_path}']"
  end

  test 'a supply by carrier is saved in Honey, without Tiny, with the carrier and no receiver needed' do
    post stock_transfers_path, params: { b2b_order: { transfer_location_id: @location.id, carrier_id: @carrier.id, receiver_name: '',
                                                      b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }] } }

    order = B2bOrder.last
    assert order.stock_transfer_by_carrier?
    assert order.aberto?
    assert_not_requested @tiny
    assert_equal 1, StockReservation.reserved_for('SKU1', account: :b2b)
  end

  test 'a supply by hand still needs the receiver' do
    assert_no_difference 'B2bOrder.count' do
      post stock_transfers_path, params: { b2b_order: { transfer_location_id: @location.id, carrier_id: '', receiver_name: '',
                                                        b2b_order_items_attributes: [{ sku: 'SKU1', name: 'Produto', quantity: 1, price: 10 }] } }
    end
  end
end
