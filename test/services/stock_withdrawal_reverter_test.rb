require 'test_helper'
require 'webmock/minitest'

class StockWithdrawalReverterTest < ActiveSupport::TestCase
  GRAPHQL_URL = 'https://chasebrasil.myshopify.com/admin/api/2025-01/graphql.json'.freeze

  def setup
    ENV['CHASE_ORDERS_TOKEN'] = 'fake-shopify-token'
    @user = User.create!(name: 'Reversor', email: 'reversor@example.com', password: 'password123')
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @a = Product.create!(sku: 'A', shopify_product_name: 'Produto A', shopify_inventory_item_id: '9001', stock_lagoa_seca: '8')
    @b = Product.create!(sku: 'B', shopify_product_name: 'Produto B', shopify_inventory_item_id: '9002', stock_bh_shopping: '5')
    @graphql_calls = []
  end

  # statuses: um por linha, na ordem de items
  def withdrawal_with(lines, status: :completed)
    withdrawal = StockWithdrawal.new(user: @user, withdrawal_date: Date.new(2026, 9, 21), reason: 'damaged')
    lines.each { |product, location, quantity, _| withdrawal.items.build(product: product, location: location, quantity: quantity) }
    withdrawal.save!
    withdrawal.items.zip(lines).each { |item, line| item.update!(status: line[3] || :done, available_before: 10, withdrawn_at: Time.current) }
    withdrawal.update_columns(status: StockWithdrawal.statuses[status])
    withdrawal
  end

  def stub_adjust(user_errors: [])
    stub_request(:post, GRAPHQL_URL).to_return do |request|
      @graphql_calls << JSON.parse(request.body)['variables']['input']
      data = { inventoryAdjustQuantities: { userErrors: user_errors, inventoryAdjustmentGroup: user_errors.empty? ? { id: 'gid://shopify/InventoryAdjustmentGroup/77' } : nil } }
      { body: { data: data }.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  test 'reverting a done line adds the quantity back in Shopify with a positive delta and a reversal reference' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @bh, 3]])
    item = withdrawal.items.first
    stub_adjust

    StockWithdrawalReverter.call(item, user: @user)

    assert_equal 1, @graphql_calls.size
    call = @graphql_calls.first
    assert_equal 'available', call['name']
    assert_equal 'correction', call['reason']
    assert_equal [{ 'inventoryItemId' => 'gid://shopify/InventoryItem/9001', 'locationId' => 'gid://shopify/Location/111', 'delta' => 2 }], call['changes']
    assert_equal "honey://stock-withdrawal/#{withdrawal.id}?motivo=reversao&linha=#{item.id}", call['referenceDocumentUri']
  end

  test 'the line becomes reverted with when, by whom and the Shopify adjustment id' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @bh, 3]])
    item = withdrawal.items.first
    stub_adjust

    StockWithdrawalReverter.call(item, user: @user)

    item.reload
    assert item.reverted?
    assert item.locked?
    assert_not_nil item.reverted_at
    assert_equal @user.id, item.reverted_by_id
    assert_equal 'gid://shopify/InventoryAdjustmentGroup/77', item.reversal_adjustment_id
  end

  test 'the local stock of the product in that location goes back up' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_adjust

    StockWithdrawalReverter.call(withdrawal.items.first, user: @user)

    assert_equal '10', @a.reload.stock_lagoa_seca
  end

  test 'the withdrawal becomes partially completed when other lines stay withdrawn' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @bh, 3]])
    stub_adjust

    StockWithdrawalReverter.call(withdrawal.items.first, user: @user)

    withdrawal.reload
    assert withdrawal.partially_completed?
    assert_equal 'Parcialmente concluída', withdrawal.status_label
  end

  test 'the withdrawal becomes reverted when every withdrawn line was reverted' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2], [@b, @bh, 3]])
    stub_adjust

    withdrawal.items.each { |item| StockWithdrawalReverter.call(item.reload, user: @user) }

    assert withdrawal.reload.reverted?
    assert_equal 'Revertida', withdrawal.status_label
  end

  test 'a withdrawal that still has failed lines keeps showing as completed with failures' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2, :done], [@b, @bh, 3, :failed]], status: :partially_failed)
    stub_adjust

    StockWithdrawalReverter.call(withdrawal.items.first, user: @user)

    assert withdrawal.reload.partially_failed?, 'a linha com falha continua pendente de retirada'
    assert withdrawal.items.first.reverted?
  end

  test 'only a done line can be reverted, and never twice' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2, :done], [@b, @bh, 3, :failed]], status: :partially_failed)
    stub_adjust

    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(withdrawal.items.second, user: @user) }

    done = withdrawal.items.first
    StockWithdrawalReverter.call(done, user: @user)
    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(done.reload, user: @user) }
    assert_equal 1, @graphql_calls.size, 'Shopify só recebe a devolução uma vez'
  end

  test 'a stale copy of the item (double click) is refused after the first reversal' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stale_copy = StockWithdrawalItem.find(withdrawal.items.first.id)
    stub_adjust

    StockWithdrawalReverter.call(withdrawal.items.first, user: @user)

    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(stale_copy, user: @user) }
    assert_equal 1, @graphql_calls.size
  end

  test 'a rejection from Shopify leaves the line and the withdrawal untouched and reports the reason' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_adjust(user_errors: [{ field: %w[input], message: 'Item não rastreado' }])

    error = assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(withdrawal.items.first, user: @user) }

    assert_match(/Item não rastreado/, error.message)
    assert withdrawal.items.first.reload.done?
    assert withdrawal.reload.completed?
    assert_equal '8', @a.reload.stock_lagoa_seca
  end

  test 'a network failure is reported as an error and changes nothing' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_request(:post, GRAPHQL_URL).to_timeout

    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(withdrawal.items.first, user: @user) }

    assert withdrawal.items.first.reload.done?
  end

  test 'a withdrawal being processed right now cannot have lines reverted' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]], status: :processing)
    withdrawal.update_columns(updated_at: 1.minute.ago)
    stub_adjust

    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(withdrawal.items.first, user: @user) }
    assert_empty @graphql_calls
  end

  test 'a location without a Shopify id cannot be reverted' do
    orphan = Location.create!(slug: 'nova', name: 'Nova', shopify_location_id: nil)
    withdrawal = withdrawal_with([[@a, orphan, 1]])
    stub_adjust

    assert_raises(StockWithdrawalReverter::Error) { StockWithdrawalReverter.call(withdrawal.items.first, user: @user) }
    assert_empty @graphql_calls
  end

  test 'the reversal is recorded in the audit log' do
    withdrawal = withdrawal_with([[@a, @lagoa, 2]])
    stub_adjust

    assert_difference 'Log.count', 1 do
      StockWithdrawalReverter.call(withdrawal.items.first, user: @user)
    end

    log = Log.last
    assert_equal 'stock_withdrawal', log.resource_type
    assert_equal 'revert_item', log.action_type
    assert_equal @user, log.user
    assert_equal 2, log.details_parsed['quantity']
    assert_equal 'A', log.details_parsed['sku']
  end
end
