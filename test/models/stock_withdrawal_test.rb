require 'test_helper'

class StockWithdrawalTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Retirada', email: 'retirada@example.com', password: 'password123')
    @lagoa = Location.create!(slug: 'lagoa_seca', name: 'Lagoa Seca', shopify_location_id: '111')
    @bh = Location.create!(slug: 'bh_shopping', name: 'BH Shopping', shopify_location_id: '222')
    @product = Product.create!(sku: 'SKU-1', shopify_product_name: 'Camiseta', shopify_inventory_item_id: '9001')
  end

  def build_withdrawal(items: [[@product, @lagoa, 2]], **attrs)
    withdrawal = StockWithdrawal.new({ user: @user, withdrawal_date: Date.new(2026, 9, 21), reason: 'shrinkage' }.merge(attrs))
    items.each { |product, location, quantity| withdrawal.items.build(product: product, location: location, quantity: quantity) }
    withdrawal
  end

  test 'is valid with a date, a Shopify reason and at least one item' do
    assert build_withdrawal.valid?
  end

  test 'starts as a draft, is editable and processable' do
    withdrawal = build_withdrawal
    withdrawal.save!

    assert withdrawal.draft?
    assert withdrawal.editable?
    assert withdrawal.processable?
  end

  test 'requires at least one item' do
    withdrawal = build_withdrawal(items: [])

    refute withdrawal.valid?
    assert_includes withdrawal.errors.full_messages.to_sentence, 'pelo menos um item'
  end

  test 'the reason must be one Shopify accepts' do
    assert_equal %w[shrinkage damaged correction quality_control other], StockWithdrawal::REASONS.keys
    refute build_withdrawal(reason: 'foguete').valid?
  end

  test 'item quantity must be a positive integer' do
    [0, -1].each { |quantity| refute build_withdrawal(items: [[@product, @lagoa, quantity]]).valid?, "#{quantity} deveria ser inválido" }
    assert build_withdrawal(items: [[@product, @lagoa, 1]]).valid?
  end

  test 'the same product cannot be listed twice for the same location' do
    duplicated = build_withdrawal(items: [[@product, @lagoa, 1], [@product, @lagoa, 2]])
    refute duplicated.valid?

    assert build_withdrawal(items: [[@product, @lagoa, 1], [@product, @bh, 2]]).valid?
  end

  test 'a product without the Shopify inventory item id is refused up front' do
    unlinked = Product.create!(sku: 'SEM-ID', shopify_product_name: 'Sem vínculo')

    withdrawal = build_withdrawal(items: [[unlinked, @lagoa, 1]])

    refute withdrawal.valid?
    assert_match(/SEM-ID/, withdrawal.errors.full_messages.to_sentence)
  end

  test 'totals and the reference uri used in the Shopify history' do
    withdrawal = build_withdrawal(items: [[@product, @lagoa, 2], [@product, @bh, 3]])
    withdrawal.save!

    assert_equal 5, withdrawal.total_quantity
    assert_equal [@lagoa, @bh].map(&:id).sort, withdrawal.locations.map(&:id).sort
    assert_equal "honey://stock-withdrawal/#{withdrawal.id}", withdrawal.reference_uri
  end

  test 'only draft withdrawals are editable; only draft and partially failed are processable' do
    withdrawal = build_withdrawal
    withdrawal.save!

    withdrawal.status = :completed
    refute withdrawal.editable?
    refute withdrawal.processable?
    withdrawal.status = :partially_failed
    refute withdrawal.editable?
    assert withdrawal.processable?
    withdrawal.status = :processing
    refute withdrawal.processable?
  end
end
