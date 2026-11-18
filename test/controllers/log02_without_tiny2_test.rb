require 'test_helper'
require 'minitest/mock'
require 'webmock/minitest'

# O Tiny 2 (atacado) não é mais usado: o Log02 roda só com os pedidos do Honey, e os pedidos antigos do
# Tiny 2 ainda parados nas filas são concluídos no Honey, sem chamar o Tiny.
class Log02WithoutTiny2Test < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Sem Tiny2', email: 'admin_sem_tiny2@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @client = Client.create!(responsible_name: 'Lojista', business_name: 'Loja Parceira Ltda', registration: '45.723.174/0001-10')
    sign_in @admin
  end

  def sale(**attrs)
    o = B2bOrder.new({ kind: :sale, user: @admin, client: @client, payment_method: 'pix', freight_service: 'SEDEX CORREIOS LOG+' }.merge(attrs))
    o.b2b_order_items.build(sku: 'LEG-1', name: 'Legging', quantity: 3, price: 50)
    o.save!
    o
  end

  def legacy_xml_step(tiny_order_id, transportadora:)
    Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id:, order_correios_id: tiny_order_id + 5,
                    id_nota_fiscal: tiny_order_id + 9, is_transportadora: transportadora)
    Attempt.create!(kinds: :emission_invoice_tiny2, status: :success, tiny_order_id:, order_correios_id: tiny_order_id + 5)
  end

  test 'the Log02 screens never call the Tiny' do
    sale
    legacy_xml_step(903_000_001, transportadora: false)

    [order_correios_create_b2b_dashboard_index_path, order_correios_create_queue_b2b_dashboard_index_path, send_xml_b2b_dashboard_index_path,
     push_tracking_b2b_dashboard_index_path, order_correios_stock_errors_b2b_dashboard_index_path, order_correios_tracking_b2b_dashboard_index_path].each do |path|
      get path
      assert_response :success, path
    end
    assert_not_requested :any, /api\.tiny\.com\.br/
  end

  test 'the XML screen lists the old Tiny 2 orders apart, with Concluir and without the send button' do
    legacy_xml_step(903_000_001, transportadora: false)

    get send_xml_b2b_dashboard_index_path

    assert_match(/Pedidos antigos do Tiny 2/, response.body)
    assert_select "form[action='#{complete_send_xml_b2b_dashboard_index_path}']", 1
    assert_no_match(/runQueueItemNow/, response.body)
  end

  test 'Concluir takes an old Correios order out of the XML and tracking queues without calling the Tiny' do
    step = legacy_xml_step(903_000_001, transportadora: false)
    queue_attempt = Attempt.find_by(kinds: :create_correios_order_tiny2, tiny_order_id: 903_000_001)

    post complete_send_xml_b2b_dashboard_index_path, params: { attempt_id: queue_attempt.id }

    assert_redirected_to send_xml_b2b_dashboard_index_path
    assert_equal 1, Attempt.where(kinds: :send_xml_tiny2, status: :success, order_correios_id: step.order_correios_id).count
    assert_equal 1, Attempt.where(kinds: :get_tracking_tiny2, status: :success, order_correios_id: step.order_correios_id).count
    assert_not_requested :any, /api\.tiny\.com\.br/

    get send_xml_b2b_dashboard_index_path
    assert_select "form[action='#{complete_send_xml_b2b_dashboard_index_path}']", 0
  end

  test 'Concluir an old carrier order only takes it out of the XML queue' do
    legacy_xml_step(903_000_002, transportadora: true)
    queue_attempt = Attempt.find_by(kinds: :create_correios_order_tiny2, tiny_order_id: 903_000_002)

    post complete_send_xml_b2b_dashboard_index_path, params: { attempt_id: queue_attempt.id }

    assert Attempt.where(kinds: :send_xml_tiny2, status: :success, is_transportadora: true, tiny_order_id: 903_000_002).exists?
    refute Attempt.where(kinds: :get_tracking_tiny2, tiny_order_id: 903_000_002).exists?
  end

  test 'the XML screen shows the Correios number and Concluir for Honey orders, and no Ver pedido' do
    order = sale(status: :preparando_envio, correios_order_id: 25_000_123)

    get send_xml_b2b_dashboard_index_path

    assert_select 'th', text: 'Nº no Correios'
    assert_select 'tbody td .correios-number', text: '25000123' do
      assert_select '.correios-flag .fa-envelope', 1
    end
    assert_select 'form[action=?]', complete_honey_order_b2b_dashboard_index_path(id: order.id), 1
    assert_select "[data-tip='Ver o pedido']", 0
    assert_select "a.pg-pn[href='#{edit_b2b_order_path(order)}']", text: 'P'
  end

  test 'the approval screen, where orders have no Correios number yet, keeps the column hidden' do
    sale

    get order_correios_create_b2b_dashboard_index_path

    assert_select 'th', text: 'Nº no Correios', count: 0
  end

  test 'Concluir takes a Honey order out of the XML and tracking queues without sending anything' do
    order = sale(status: :preparando_envio, correios_order_id: 25_000_123)

    post complete_honey_order_b2b_dashboard_index_path(id: order.id)

    assert_redirected_to send_xml_b2b_dashboard_index_path
    order.reload
    assert_equal 'completed', order.log_stage
    assert order.enviado?
    assert_empty B2bOrder.waiting_xml
    assert_empty B2bOrder.waiting_tracking
    assert Attempt.exists?(kinds: :send_xml_honey, status: :success, b2b_order_id: order.id)
    HoneyB2bLog.stub(:send_xml, ->(_) { flunk 'não pode enviar o XML' }) { HoneyB2bLog.send_pending_xml! }

    get order_correios_tracking_b2b_dashboard_index_path
    assert_select 'tbody', text: /Concluído à mão/
  end

  test 'Concluir only works while the Honey order waits for the XML' do
    order = sale(status: :aberto)

    post complete_honey_order_b2b_dashboard_index_path(id: order.id)

    assert_match(/não está esperando/, flash[:alert])
    assert order.reload.aberto?
    assert_not order.log_ignored?
  end

  test 'the old Emissão de Notas step goes to the NF-e e XML step' do
    get invoice_emition_b2b_dashboard_index_path

    assert_redirected_to send_xml_b2b_dashboard_index_path
  end

  test 'Produtos Sem Estoque lists the approved Honey orders the Correios refused for missing stock' do
    order = sale(status: :aprovado)
    Attempt.create!(kinds: :create_correios_order_honey, status: :fail, b2b_order_id: order.id,
                    message: 'Produto(s) informado(s) não existe(m) no estoque: LEG-1')

    get order_correios_stock_errors_b2b_dashboard_index_path

    assert_response :success
    assert_select "a[href='#{edit_b2b_order_path(order)}']"
    assert_match(/LEG-1/, response.body)
  end

  test 'the Log02 routines run only the Honey orders' do
    calls = []
    HoneyB2bLog.stub(:create_pending!, -> { calls << :create }) do
      HoneyB2bLog.stub(:send_pending_xml!, -> { calls << :xml }) do
        CreateCorreiosLogOrdersJob2.perform_now('all', nil)
        SendXmlCorreiosLogJob2.perform_now('all', nil)
      end
    end

    assert_equal %i[create xml], calls
    assert_not_requested :any, /api\.tiny\.com\.br/
  end
end
