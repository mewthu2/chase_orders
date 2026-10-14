require 'test_helper'
require_relative '../support/cashback_factory'

class CashbackUnificationTest < ActiveSupport::TestCase
  include CashbackFactory
  self.fixture_table_names = []

  setup { setup_cashback }
  teardown { travel_back }

  test 'sums exact decimal amounts and minimums and selects the earliest expiry' do
    result = preview(codes: [' mtza ', 'mtzb'])
    assert_equal BigDecimal('50.30'), result[:amount]
    assert_equal BigDecimal('250.03'), result[:minimum_purchase]
    assert_equal 1.day.from_now, result[:expires_at]
    assert_empty @gateway.writes
  end

  test 'unbound cashback requires attestation and creates a customer restricted UNF' do
    @gateway.nodes.each_value { |node| node['codeDiscount']['context'] = { '__typename' => 'DiscountBuyerSelectionAll' } }
    assert_raises(Cashback::Preview::Error) { preview }
    record = CashbackUnification.create!(preview(ownership_confirmed: true).merge(user: @user, code: 'UNFTEST'))
    unify(record)
    assert_equal({ customers: { add: ['gid://shopify/Customer/123'] } }, @gateway.inputs.first[:context])
    assert record.reload.ownership_confirmed?
  end

  test 'attestation cannot override a different linked customer' do
    @gateway.nodes['MTZB']['codeDiscount']['context']['customers'] = [{ 'id' => 'gid://shopify/Customer/999' }]
    assert_raises(Cashback::Preview::Error) { preview(ownership_confirmed: true) }
  end

  test 'rejects duplicate codes, UNF inputs, missing coupons and missing customers' do
    [%w[MTZA mtza], %w[UNFA MTZB], %w[MTZMISSING MTZB]].each do |codes|
      assert_raises(Cashback::Preview::Error) { preview(codes: codes) }
    end
    @customer.update!(shopify_customer_id: nil)
    assert_raises(Cashback::Preview::Error) { preview }
    assert_empty @gateway.writes
  end

  test 'rejects used expired scheduled percentage foreign currency and unsupported rules' do
    changes = [
      ->(data) { data['asyncUsageCount'] = 1 },
      ->(data) { data['asyncUsageCount'] = nil },
      ->(data) { data['status'] = 'EXPIRED' },
      ->(data) { data['endsAt'] = Time.current.iso8601 },
      ->(data) { data['endsAt'] = nil },
      ->(data) { data['startsAt'] = 1.hour.from_now.iso8601 },
      ->(data) { data['usageLimit'] = nil },
      ->(data) { data['customerGets']['value']['__typename'] = 'DiscountPercentage' },
      ->(data) { data['customerGets']['value']['amount']['currencyCode'] = 'USD' },
      ->(data) { data['customerGets']['value']['amount']['amount'] = 'NaN' },
      ->(data) { data['customerGets']['value']['amount']['amount'] = '1.001' },
      ->(data) { data['customerGets']['value']['appliesOnEachItem'] = true },
      ->(data) { data['customerGets']['items']['__typename'] = 'DiscountCollections' },
      ->(data) { data['customerGets']['appliesOnSubscription'] = true },
      ->(data) { data['minimumRequirement'] = nil },
      ->(data) { data['minimumRequirement']['greaterThanOrEqualToSubtotal']['amount'] = '0' },
      ->(data) { data['codes']['nodes'] << { 'code' => 'MTZOTHER' } },
      ->(data) { data['codes']['pageInfo']['hasNextPage'] = true },
      ->(data) { data['combinesWith']['shippingDiscounts'] = true },
      ->(data) { data['context'] = { '__typename' => 'DiscountCustomerSegments' } }
    ]
    original = @gateway.nodes['MTZB'].deep_dup
    changes.each_with_index do |change, index|
      @gateway.nodes['MTZB'] = original.deep_dup
      change.call(@gateway.nodes['MTZB']['codeDiscount'])
      assert_raises(Cashback::Preview::Error, "change #{index}") { preview(ownership_confirmed: true) }
    end
  end

  test 'deactivates both originals before creating one verified single use replacement' do
    record = draft_unification
    unify(record)
    assert record.reload.completed?
    assert_equal [:deactivate, :deactivate, :create], @gateway.writes.map(&:first)
    assert_equal 2, record.sources.count
    input = @gateway.inputs.first
    assert_equal '50.3', input.dig(:customerGets, :value, :discountAmount, :amount)
    assert_equal '250.03', input.dig(:minimumRequirement, :subtotal, :greaterThanOrEqualToSubtotal)
    assert_equal 1.day.from_now.iso8601, input[:endsAt]
    assert_equal 1, input[:usageLimit]
    assert_equal true, input[:appliesOncePerCustomer]
    assert Log.where(resource_type: 'discount', action_type: 'unify', success: true).exists?
    unify(record)
    assert_equal 3, @gateway.writes.size, 'repeated confirmation must not issue more writes'
  end

  test 'claims prevent overlapping pairs including when a new preview predates confirmation' do
    first = draft_unification
    second = draft_unification
    unify(first)
    assert_raises(Cashback::Unify::Error) { unify(second) }
    assert_equal 3, @gateway.writes.size
    assert_equal 0, second.sources.count
  end

  test 'source claims survive a process interruption' do
    first = draft_unification
    first.update!(status: :processing, step: 'deactivate_1')
    first.source_snapshots.each { |source| first.sources.create!(shopify_node_id: source['node_id']) }
    assert_raises(Cashback::Unify::Error) { unify(first) }
    assert_raises(Cashback::Unify::Error) { unify(draft_unification) }
    assert_empty @gateway.writes
  end

  test 'changes after preview reject without writes and release source claims' do
    record = draft_unification
    @gateway.nodes['MTZB']['codeDiscount']['customerGets']['value']['amount']['amount'] = '40.20'
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert record.reload.rejected?
    assert_empty @gateway.writes
    assert_empty record.sources
  end

  test 'old previews cannot be confirmed' do
    record = draft_unification
    travel 11.minutes
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert_empty @gateway.writes
    assert_empty record.sources
  end

  test 'second deactivation failure retains durable evidence and never creates replacement' do
    record = draft_unification
    @gateway.before_deactivate = ->(id) { raise Timeout::Error if id.end_with?('/2') }
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert record.reload.needs_review?
    assert_equal 'deactivate_2', record.step
    assert_equal 2, record.sources.count
    assert_equal [:deactivate, :deactivate], @gateway.writes.map(&:first)
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert_equal 2, @gateway.writes.size
  end

  test 'successful create with lost response cannot cause a duplicate on resubmission' do
    record = draft_unification
    @gateway.after_create = -> { raise Timeout::Error, 'response lost' }
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert record.reload.needs_review?
    assert_equal 'create', record.step
    assert @gateway.nodes[record.code], 'the reserved code allows reconciliation even without a response'
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert_equal 1, @gateway.inputs.size
  end

  test 'new usage detected after deactivation blocks creation' do
    record = draft_unification
    @gateway.after_deactivate = ->(_id) { @gateway.nodes['MTZA']['codeDiscount']['asyncUsageCount'] = 1 }
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert record.reload.needs_review?
    assert_empty @gateway.inputs
  end

  test 'replacement with wrong values is never reported as completed' do
    record = draft_unification
    @gateway.after_create = -> { @gateway.nodes[record.code]['codeDiscount']['minimumRequirement']['greaterThanOrEqualToSubtotal']['amount'] = '1.00' }
    assert_raises(Cashback::Unify::Error) { unify(record) }
    assert record.reload.needs_review?
    assert_equal 'verify', record.step
  end
end
