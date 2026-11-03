require 'test_helper'
require 'webmock/minitest'

# As telas no padrão do protótipo (motor de páginas) abrem com dados e trazem indicadores,
# filtros, a lista e o painel "Ver".
class HoneyPagesRenderTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Telas', email: 'admin_telas@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    sign_in @admin
    @location = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @customer = Customer.create!(first_name: 'Maria', last_name: 'Souza', email: 'maria@example.com', orders_count: 3, total_spent: 450, shopify_customer_id: 'c1')
    Order.create!(shopify_order_id: '5001', customer: @customer, location: @location, discount_codes: ['BEMVINDA10'], current_total_price: 199.9,
                  current_total_discounts: 20, shopify_creation_date: 2.days.ago)
  end

  def assert_engine_page
    assert_response :success
    assert_select '.pg-kpis .stat-card', minimum: 1
    assert_select '.table-card.pg-card'
  end

  test 'ecommerce customers' do
    get customers_path
    assert_engine_page
    assert_select 'tbody .person', text: /Maria Souza/
    assert_select 'script[type="text/html"][id^="pgd-main-"]'

    get customers_path(q: 'ninguem-com-esse-nome')
    assert_select '.pg-empty h3', text: 'Nada com esses filtros'
  end

  test 'shopify orders with filters and kpis' do
    get orders_path
    assert_engine_page
    assert_select 'tbody a.text-main', text: '#5001'
    assert_select '.pg-tag', text: 'BEMVINDA10'

    get orders_path(kpi: 2)
    assert_select 'tbody a.text-main', text: '#5001'
    get orders_path(loja: @location.id, per: 7)
    assert_select 'tbody tr', count: 1
  end

  test 'coupon usage ranking' do
    get coupon_usage_orders_path
    assert_engine_page
    assert_select '.pg-bars', count: 2
    assert_select 'tbody .pg-mono', text: 'BEMVINDA10'
  end

  test 'transfer approvers configuration' do
    get edit_internal_transfer_config_path
    assert_response :success
    assert_select '.pg-split .pg-inline input[type=checkbox][name="approver_ids[]"]', minimum: 1
    assert_select '.pg-howto li', count: 5
  end

  test 'cashback unifications' do
    get cashback_unifications_path
    assert_engine_page
  end

  test 'transfer locations' do
    TransferLocation.create!(name: 'Loja Centro', registration: '25.405.327/0001-74', street: 'Rua A', number: '1', neighbourhood: 'Centro', city: 'Belo Horizonte', state: 'MG', zip: '30000-000')
    get transfer_locations_path
    assert_engine_page
    assert_select '.pg-kpi', text: /Sem código IBGE\s*1/
  end

  test 'stock sync, planner and attempts screens' do
    Attempt.create!(kinds: :sync_correios_stock, status: :success, tracking: 'manual_execution:1', message: 'Tudo certo')
    get stock_syncs_path
    assert_engine_page
    assert_select 'script#syncScheduleForm'

    PlannerOrder.create!(reference: 'PO-2026-1', status: :saved, user: @admin)
    get planner_orders_path
    assert_engine_page
    assert_select 'tbody .pg-mono', text: 'PO-2026-1'

    Attempt.create!(kinds: :send_xml, status: :fail, tiny_order_id: 4242, message: 'Recusado')
    get attempts_path(channel: 'b2c')
    assert_engine_page
    assert_select 'tbody .pg-mono', text: '4242'
    get attempts_path(channel: 'b2c', status: 'fail', kinds: 'send_xml')
    assert_select 'tbody tr', count: 1
  end

  test 'log03 queues, tracking, pipeline and api screens' do
    stub_request(:get, /api\.tiny\.com\.br/).to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)
    Attempt.create!(kinds: :create_correios_order, status: :success, tiny_order_id: 5150, order_correios_id: 9150)
    Attempt.create!(kinds: :emission_invoice, status: :success, tiny_order_id: 5151, order_correios_id: 9151)
    Attempt.create!(kinds: :create_correios_order, status: :success, tiny_order_id: 5151, order_correios_id: 9151)

    get invoice_emition_dashboard_index_path
    assert_engine_page
    assert_select '.pg-flow .pg-flow-step.is-current', text: /Emissão de Notas/
    assert_select '.pg-run'

    [send_xml_dashboard_index_path, push_tracking_dashboard_index_path, order_correios_create_dashboard_index_path,
     order_correios_stock_errors_dashboard_index_path, order_correios_tracking_dashboard_index_path].each do |path|
      get path
      assert_response :success, path
      assert_select '.pg-kpis', { minimum: 1 }, path
    end

    get correios_pipeline_dashboard_index_path
    assert_response :success
    assert_select '#pipelineContent'
    get api_correios_dashboard_index_path
    assert_response :success
    assert_select '.pg-lookup #item_code'
  end

  test 'log02 screens' do
    stub_request(:get, /api\.tiny\.com\.br/).to_return(body: { retorno: { status: 'Erro', codigo_erro: '20', erros: [{ erro: 'A consulta não retornou registros' }] } }.to_json)
    [order_correios_create_b2b_dashboard_index_path, order_correios_create_queue_b2b_dashboard_index_path, invoice_emition_b2b_dashboard_index_path,
     send_xml_b2b_dashboard_index_path, push_tracking_b2b_dashboard_index_path, order_correios_stock_errors_b2b_dashboard_index_path,
     order_correios_tracking_b2b_dashboard_index_path, api_correios_b2b_dashboard_index_path].each do |path|
      get path
      assert_response :success, path
    end
  end
end
