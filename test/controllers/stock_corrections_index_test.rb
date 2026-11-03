require 'test_helper'

class StockCorrectionsIndexTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(name: 'Admin Conferência', email: 'admin_correction@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111', kpi_ratio: 97, kpi_updated_at: 1.hour.ago)
    @a = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta Azul', shopify_inventory_item_id: '9001')
    @b = Product.create!(sku: 'SKU-B', shopify_product_name: 'Calça Preta', shopify_inventory_item_id: '9002')
    sign_in @admin
  end

  def correction(reason:, status: 'pending', errors: 0, corrected: 0)
    record = StockCorrection.create!(location: 'lagoa_seca', correction_date: Date.current, reason: reason, status: status, user: @admin)
    [@a, @b].each_with_index do |product, i|
      record.stock_correction_items.create!(product: product, needs_correction: i < corrected + errors,
                                            shopify_sync_status: i < errors ? 'error' : 'pending',
                                            current_stock: 5, corrected_stock: 4, correction_reason: 'Contagem física')
    end
    record
  end

  test 'the list shows indicators, typed rows and the accuracy table' do
    correction(reason: 'Inventário mensal', errors: 1)
    correction(reason: 'Auditoria', status: 'executed', corrected: 2)

    get stock_corrections_path

    assert_response :success
    assert_select '.pg-kpi', text: /Pendentes\s*1/
    assert_select '.pg-kpi', text: /Com erro no Shopify\s*1/
    assert_select '.pg-kpi', text: /Correções feitas\s*3/
    assert_select 'tbody tr', minimum: 2
    assert_select '.cell-sub', text: 'Erro no Shopify'
    assert_select '#acuracia .pg-prog'
    assert_select '#acuracia .ticket-status', text: 'Boa'
  end

  test 'filters by search, status and the Shopify error indicator' do
    pending = correction(reason: 'Inventário mensal', errors: 1)
    executed = correction(reason: 'Auditoria', status: 'executed')

    get stock_corrections_path(q: 'audit')
    assert_select 'tbody a.text-main', text: "##{executed.id}"
    assert_select 'tbody a.text-main', text: "##{pending.id}", count: 0

    get stock_corrections_path(status: 'pending')
    assert_select 'tbody a.text-main', text: "##{executed.id}", count: 0
    assert_select '.filter-chip', text: /Status: Pendente/

    get stock_corrections_path(kpi: 'error')
    assert_select 'tbody a.text-main', text: "##{pending.id}"
    assert_select 'tbody a.text-main', text: "##{executed.id}", count: 0
  end

  test 'sorts by number of items and shows the empty state for filters without results' do
    correction(reason: 'Inventário mensal')

    get stock_corrections_path(sort: 'items', dir: 'asc')
    assert_response :success
    assert_select 'a.pg-th .fa-sort-up'

    get stock_corrections_path(q: 'nada-disso')
    assert_select '.pg-empty h3', text: 'Nada com esses filtros'
  end
end
