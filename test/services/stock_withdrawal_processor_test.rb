require 'test_helper'
require 'webmock/minitest'

class StockWithdrawalProcessorTest < ActiveSupport::TestCase
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze
  LEVELS_URL = %r{\Ahttps://chasebrasil\.myshopify\.com/admin/api/2025-01/inventory_levels\.json}

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @user = User.create!(name: 'Processador', email: 'processador@example.com', password: 'password123')
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'A', shopify_product_name: 'Produto A', shopify_inventory_item_id: '9001', stock_lagoa_seca: '10')
    @b = Product.create!(sku: 'B', shopify_product_name: 'Produto B', shopify_inventory_item_id: '9002', stock_lagoa_seca: '3')
    @graphql_calls = []
  end

  def withdrawal_with(items, **attrs)
    withdrawal = StockWithdrawal.new({ user: @user, withdrawal_date: Date.new(2026, 9, 21), reason: 'damaged' }.merge(attrs))
    items.each { |product, location, quantity| withdrawal.items.build(product: product, location: location, quantity: quantity) }
    withdrawal.save!
    withdrawal
  end

  # available: { 'location_id' => { 'inventory_item_id' => quantidade } }
  def stub_levels(available)
    stub_request(:get, LEVELS_URL).to_return do |request|
      query = Addressable::URI.parse(request.uri).query_values
      location = query['location_ids']
      levels = query['inventory_item_ids'].split(',').filter_map do |item_id|
        quantity = available.dig(location, item_id)
        { inventory_item_id: item_id.to_i, location_id: location.to_i, available: quantity } unless quantity == :missing
      end
      { body: { inventory_levels: levels }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  def stub_adjust(user_errors: nil)
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      input = JSON.parse(request.body)['variables']['input']
      @graphql_calls << input
      errors = user_errors&.call(input) || []
      data = { inventoryAdjustQuantities: { userErrors: errors, inventoryAdjustmentGroup: errors.empty? ? { id: "gid://shopify/InventoryAdjustmentGroup/#{@graphql_calls.size}" } : nil } }
      { body: { data: data }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'withdraws from Shopify with one call per location, a negative delta, the reason and the reference' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @lagoa, 1], [@a, @bh, 4]])
    stub_levels('111' => { '9001' => 10, '9002' => 3 }, '222' => { '9001' => 20 })
    stub_adjust

    summary = StockWithdrawalProcessor.call(withdrawal)

    assert_equal 2, @graphql_calls.size
    lagoa_call = @graphql_calls.find { |c| c['changes'].first['locationId'] == 'gid://shopify/Location/111' }
    assert_equal 'available', lagoa_call['name']
    assert_equal 'damaged', lagoa_call['reason']
    assert_equal withdrawal.reference_uri, lagoa_call['referenceDocumentUri']
    assert_equal({ 'gid://shopify/InventoryItem/9001' => -2, 'gid://shopify/InventoryItem/9002' => -1 },
                 lagoa_call['changes'].to_h { |c| [c['inventoryItemId'], c['delta']] })
    assert_equal %w[gid://shopify/InventoryItem/9001 gid://shopify/InventoryItem/9002], lagoa_call['changes'].map { |c| c['inventoryItemId'] }.sort
    bh_call = @graphql_calls.find { |c| c['changes'].first['locationId'] == 'gid://shopify/Location/222' }
    assert_equal [-4], bh_call['changes'].map { |c| c['delta'] }

    withdrawal.reload
    assert withdrawal.completed?
    assert_not_nil withdrawal.completed_at
    assert withdrawal.items.all?(&:done?)
    assert_equal 3, summary.done
    assert_equal 0, summary.failed
    assert_equal [10, 3, 20], withdrawal.items.order(:id).map(&:available_before)
    assert(withdrawal.items.all? { |i| i.shopify_adjustment_id.present? && i.withdrawn_at.present? })
  end

  test 'updates the local stock of the product in the location after withdrawing' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_levels('111' => { '9001' => 10 })
    stub_adjust

    StockWithdrawalProcessor.call(withdrawal)

    assert_equal '8', @a.reload.stock_lagoa_seca
  end

  test 'lines that exceed the available stock are not withdrawn and are reported, the others go on' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @lagoa, 5]])
    stub_levels('111' => { '9001' => 10, '9002' => 3 })
    stub_adjust

    StockWithdrawalProcessor.call(withdrawal)

    assert_equal 1, @graphql_calls.size
    assert_equal ['gid://shopify/InventoryItem/9001'], @graphql_calls.first['changes'].map { |c| c['inventoryItemId'] }
    withdrawal.reload
    assert withdrawal.partially_failed?
    ok = withdrawal.items.find_by(product: @a)
    failed = withdrawal.items.find_by(product: @b)
    assert ok.done?
    assert failed.failed?
    assert_match(/Estoque insuficiente.*disponível 3.*retirada 5/, failed.error_message)
    assert_equal '3', @b.reload.stock_lagoa_seca, 'a linha que falhou não altera o estoque local'
  end

  test 'a product not stocked in the location or not tracked is reported' do
    withdrawal = withdrawal_with([[@a, @lagoa, 1], [@b, @lagoa, 1]])
    stub_levels('111' => { '9001' => :missing, '9002' => nil })
    stub_adjust

    StockWithdrawalProcessor.call(withdrawal)

    assert_empty @graphql_calls
    assert_match(/não encontrado nesta location/, withdrawal.items.find_by(product: @a).error_message)
    assert_match(/não rastreado/, withdrawal.items.find_by(product: @b).error_message)
    assert withdrawal.reload.partially_failed?
  end

  test 'when the group is rejected each line is retried alone so good lines still go through' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @lagoa, 1]])
    stub_levels('111' => { '9001' => 10, '9002' => 3 })
    stub_adjust(user_errors: lambda { |input|
      bad = input['changes'].any? { |c| c['inventoryItemId'].end_with?('9002') }
      bad ? [{ field: %w[input changes 0], message: 'Item não rastreado' }] : []
    })

    StockWithdrawalProcessor.call(withdrawal)

    assert_equal 3, @graphql_calls.size # grupo + 1 por linha
    withdrawal.reload
    assert withdrawal.items.find_by(product: @a).done?
    bad = withdrawal.items.find_by(product: @b)
    assert bad.failed?
    assert_match(/Item não rastreado/, bad.error_message)
    assert withdrawal.partially_failed?
  end

  test 'retrying only processes what is still pending or failed, never withdrawing twice' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @lagoa, 5]])
    stub_levels('111' => { '9001' => 10, '9002' => 3 })
    stub_adjust
    StockWithdrawalProcessor.call(withdrawal)
    assert_equal 1, @graphql_calls.size

    stub_levels('111' => { '9001' => 8, '9002' => 9 }) # o estoque de B foi reposto
    StockWithdrawalProcessor.call(withdrawal.reload)

    assert_equal 2, @graphql_calls.size
    assert_equal ['gid://shopify/InventoryItem/9002'], @graphql_calls.last['changes'].map { |c| c['inventoryItemId'] }
    assert withdrawal.reload.completed?
    assert_nil withdrawal.items.find_by(product: @b).error_message
  end

  test 'a completed withdrawal cannot be processed again and Shopify is not called' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_levels('111' => { '9001' => 10 })
    stub_adjust
    StockWithdrawalProcessor.call(withdrawal)
    calls = @graphql_calls.size

    assert_raises(StockWithdrawalProcessor::Error) { StockWithdrawalProcessor.call(withdrawal.reload) }
    assert_equal calls, @graphql_calls.size
  end

  test 'a run already in progress blocks another, but a stale one (older than 10 minutes) does not' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    withdrawal.update_columns(status: StockWithdrawal.statuses[:processing], updated_at: 1.minute.ago)
    assert_raises(StockWithdrawalProcessor::Error) { StockWithdrawalProcessor.call(withdrawal.reload) }

    withdrawal.update_columns(updated_at: 11.minutes.ago)
    stub_levels('111' => { '9001' => 10 })
    stub_adjust
    StockWithdrawalProcessor.call(withdrawal.reload)

    assert withdrawal.reload.completed?
  end

  test 'a Shopify failure does not raise: lines are marked failed with the reason' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_request(:get, LEVELS_URL).to_return(status: 500, body: 'erro')

    StockWithdrawalProcessor.call(withdrawal)

    item = withdrawal.reload.items.first
    assert item.failed?
    assert item.error_message.present?
    assert withdrawal.partially_failed?
  end

  test 'a location without a Shopify id fails its lines instead of using a default location' do
    orphan = Location.create!(slug: 'nova', name: 'Nova', shopify_location_id: nil)
    withdrawal = withdrawal_with([[@a, orphan, 1]])
    graphql = stub_adjust

    StockWithdrawalProcessor.call(withdrawal)

    assert_not_requested graphql
    assert_match(/sem ID do Shopify/, withdrawal.items.first.error_message)
  end

  test 'a location with no matching local stock column still withdraws in Shopify' do
    log = Location.create!(slug: 'log+', name: 'Correios Log +', shopify_location_id: '333')
    withdrawal = withdrawal_with([[@a, log, 1]])
    stub_levels('333' => { '9001' => 5 })
    stub_adjust

    StockWithdrawalProcessor.call(withdrawal)

    assert withdrawal.reload.completed?
  end

  test 'the completion is recorded in the audit log' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_levels('111' => { '9001' => 10 })
    stub_adjust

    assert_difference 'Log.count', 1 do
      StockWithdrawalProcessor.call(withdrawal, user: @user)
    end

    log = Log.last
    assert_equal 'stock_withdrawal', log.resource_type
    assert_equal 'complete', log.action_type
    assert_equal @user, log.user
    assert_equal 1, log.details_parsed['done']
  end
end
