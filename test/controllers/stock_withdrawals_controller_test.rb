require 'test_helper'
require 'webmock/minitest'

class StockWithdrawalsControllerTest < ActionDispatch::IntegrationTest
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @admin = User.create!(name: 'Admin Retirada', email: 'admin_withdrawal@example.com', password: 'password123')
    @admin.profiles << Profile.find(Profile::ADMIN)
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'SKU-A', shopify_product_name: 'Camiseta Azul', shopify_inventory_item_id: '9001', stock_lagoa_seca: '10')
    @b = Product.create!(sku: 'SKU-B', shopify_product_name: 'Calça Preta', shopify_inventory_item_id: '9002')
    @unlinked = Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')
    sign_in @admin
  end

  def valid_params(items: nil, **header)
    { stock_withdrawal: {
      withdrawal_date: '2026-09-21', reason: 'damaged', notes: 'Caixa molhada',
      items: items || { '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '2' }, '1' => { product_id: @a.id, location_id: @bh.id, quantity: '3' } }
    }.merge(header) }
  end

  def draft(items: [[@a, @lagoa, 2]])
    withdrawal = StockWithdrawal.new(user: @admin, withdrawal_date: Date.new(2026, 9, 21), reason: 'damaged')
    items.each { |product, location, quantity| withdrawal.items.build(product: product, location: location, quantity: quantity) }
    withdrawal.save!
    withdrawal
  end

  def stub_shopify(available: { '111' => { '9001' => 10 } })
    levels = stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      rows = query['inventory_item_ids'].split(',').filter_map do |id|
        quantity = available.dig(query['location_ids'], id)
        { inventory_item_id: id.to_i, location_id: query['location_ids'].to_i, available: quantity } if quantity
      end
      { body: { inventory_levels: rows }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
    adjust = stub_request(:post, GRAPHQL_URL).to_return(
      body: { data: { inventoryAdjustQuantities: { userErrors: [], inventoryAdjustmentGroup: { id: 'gid://shopify/InventoryAdjustmentGroup/1' } } } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
    [levels, adjust]
  end

  test 'user without the stock_withdrawals permission is redirected everywhere' do
    profile = Profile.create!(name: 'Sem Retirada')
    user = User.create!(name: 'Sem Acesso', email: 'sem_withdrawal@example.com', password: 'password123')
    user.profiles << profile
    withdrawal = draft
    sign_in user

    get stock_withdrawals_path
    assert_redirected_to root_path
    post complete_stock_withdrawal_path(withdrawal)
    assert_redirected_to root_path
    assert withdrawal.reload.draft?
  end

  test 'index lists the withdrawals and filters by status' do
    draft
    done = draft(items: [[@b, @bh, 1]])
    done.update_columns(status: StockWithdrawal.statuses[:completed])

    get stock_withdrawals_path
    assert_response :success
    assert_select 'tbody tr', count: 2

    get stock_withdrawals_path(status: 'completed')
    assert_select 'tbody tr', count: 1
    assert_select 'tbody', text: /Concluída/
  end

  test 'new form has the reason, every location and the product search' do
    get new_stock_withdrawal_path

    assert_response :success
    assert_select 'select[name="stock_withdrawal[reason]"] option', count: StockWithdrawal::REASONS.size
    assert_select 'input[name="location_ids[]"]', count: Location.count
    assert_select '#productSearchInput'
    assert_select '#itemsTable'
  end

  test 'create saves a draft with one item per product and location and never touches Shopify' do
    shopify = stub_shopify

    assert_difference ['StockWithdrawal.count'], 1 do
      assert_difference 'StockWithdrawalItem.count', 2 do
        post stock_withdrawals_path, params: valid_params
      end
    end

    withdrawal = StockWithdrawal.last
    assert withdrawal.draft?
    assert_equal @admin, withdrawal.user
    assert_equal 'damaged', withdrawal.reason
    assert_equal 5, withdrawal.total_quantity
    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_not_requested shopify.first
    assert_not_requested shopify.last
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /rascunho/i
  end

  test 'blank quantities are ignored, so the grid can send empty cells' do
    items = { '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '2' }, '1' => { product_id: @a.id, location_id: @bh.id, quantity: '' } }

    assert_difference 'StockWithdrawalItem.count', 1 do
      post stock_withdrawals_path, params: valid_params(items: items)
    end
  end

  test 'create without items re-renders with the error and keeps what was typed' do
    assert_no_difference 'StockWithdrawal.count' do
      post stock_withdrawals_path, params: valid_params(items: {}, notes: 'Não perder isto')
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /pelo menos um item/
    assert_select 'textarea[name="stock_withdrawal[notes]"]', text: /Não perder isto/
  end

  test 'a product without a Shopify inventory id is refused with its SKU' do
    items = { '0' => { product_id: @unlinked.id, location_id: @lagoa.id, quantity: '1' } }

    assert_no_difference 'StockWithdrawal.count' do
      post stock_withdrawals_path, params: valid_params(items: items)
    end

    assert_response :unprocessable_entity
    assert_select '.form-error-box', text: /SEM-ID/
  end

  test 'edit and update replace the items of a draft' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])

    get edit_stock_withdrawal_path(withdrawal)
    assert_response :success
    assert_select "input[name='stock_withdrawal[items][0][quantity]'], script", minimum: 1

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {
      '0' => { product_id: @a.id, location_id: @lagoa.id, quantity: '7' },
      '1' => { product_id: @b.id, location_id: @bh.id, quantity: '1' }
    }, reason: 'correction')

    assert_redirected_to stock_withdrawal_path(withdrawal)
    withdrawal.reload
    assert_equal 'correction', withdrawal.reason
    assert_equal [[@a.id, @lagoa.id, 7], [@b.id, @bh.id, 1]], withdrawal.items.order(:id).map { |i| [i.product_id, i.location_id, i.quantity] }
  end

  test 'an invalid update keeps the original items' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])

    patch stock_withdrawal_path(withdrawal), params: valid_params(items: {})

    assert_response :unprocessable_entity
    assert_equal 1, withdrawal.reload.items.count
  end

  test 'a completed withdrawal cannot be edited, updated or destroyed' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed])

    get edit_stock_withdrawal_path(withdrawal)
    assert_redirected_to stock_withdrawal_path(withdrawal)
    patch stock_withdrawal_path(withdrawal), params: valid_params
    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_no_difference 'StockWithdrawal.count' do
      delete stock_withdrawal_path(withdrawal)
    end
    assert_equal 1, withdrawal.reload.items.count
  end

  test 'a draft can be destroyed' do
    withdrawal = draft

    assert_difference 'StockWithdrawal.count', -1 do
      delete stock_withdrawal_path(withdrawal)
    end
    assert_redirected_to stock_withdrawals_path
  end

  test 'complete withdraws from Shopify right away and shows the result' do
    withdrawal = draft(items: [[@a, @lagoa, 2]])
    levels, adjust = stub_shopify

    assert_no_enqueued_jobs do
      post complete_stock_withdrawal_path(withdrawal)
    end

    assert_requested levels
    assert_requested adjust, times: 1
    assert withdrawal.reload.completed?
    assert_redirected_to stock_withdrawal_path(withdrawal)
    follow_redirect!
    assert_select '.flash-messages-container .alert-success', text: /Retirada concluída/
    assert_select 'tbody', text: /Retirado/
  end

  test 'complete with a failing line reports it and lets you try again' do
    withdrawal = draft(items: [[@a, @lagoa, 20]])
    stub_shopify # disponível 10 < 20

    post complete_stock_withdrawal_path(withdrawal)

    assert withdrawal.reload.partially_failed?
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger', text: /falhas/i
    assert_select 'tbody', text: /Estoque insuficiente/
    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}']", text: /Tentar novamente/
  end

  test 'complete on an already completed withdrawal is refused and Shopify is not called' do
    withdrawal = draft
    withdrawal.update_columns(status: StockWithdrawal.statuses[:completed])
    levels, adjust = stub_shopify

    post complete_stock_withdrawal_path(withdrawal)

    assert_redirected_to stock_withdrawal_path(withdrawal)
    assert_not_requested levels
    assert_not_requested adjust
    follow_redirect!
    assert_select '.flash-messages-container .alert-danger'
  end

  test 'show asks for confirmation before withdrawing and explains there is no undo' do
    withdrawal = draft

    get stock_withdrawal_path(withdrawal)

    assert_select "form[action='#{complete_stock_withdrawal_path(withdrawal)}'][data-turbo-confirm*='desfazer']"
  end

  test 'search_product returns only products linked to Shopify with their local stock by location' do
    get search_product_stock_withdrawals_path, params: { query: 'camiseta' }
    json = JSON.parse(response.body)

    assert_equal ['SKU-A'], json['products'].map { |p| p['sku'] }
    assert_equal 10, json['products'].first['stock']['lagoa_seca']

    get search_product_stock_withdrawals_path, params: { query: 'SEM-ID' }
    assert_empty JSON.parse(response.body)['products']
  end
end
