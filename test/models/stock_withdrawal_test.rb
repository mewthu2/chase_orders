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
    assert_equal %w[shrinkage damaged correction quality_control marketing other], StockWithdrawal::REASONS.keys
    assert_equal 'Marketing', StockWithdrawal::REASONS['marketing']
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
    assert_equal "honey://stock-withdrawal/#{withdrawal.id}?motivo=shrinkage", withdrawal.reference_uri
  end

  test 'draft and partially failed withdrawals are editable; only draft and partially failed are processable' do
    withdrawal = build_withdrawal
    withdrawal.save!

    withdrawal.status = :completed
    refute withdrawal.editable?
    refute withdrawal.processable?
    withdrawal.status = :partially_failed
    assert withdrawal.editable?
    assert withdrawal.processable?
    withdrawal.status = :processing
    refute withdrawal.processable?
  end

  test 'Marketing is sent to Shopify as the closest accepted reason (promotion) and kept in the reference' do
    marketing = build_withdrawal(reason: 'marketing')
    marketing.save!

    assert_equal 'promotion', marketing.shopify_reason
    assert_equal "honey://stock-withdrawal/#{marketing.id}?motivo=marketing", marketing.reference_uri
    %w[shrinkage damaged correction quality_control other].each do |reason|
      assert_equal reason, StockWithdrawal.new(reason: reason).shopify_reason, 'motivos do Shopify seguem iguais'
    end
  end

  test 'deletable? is true for every status except a run in progress (a stale run does not count)' do
    withdrawal = build_withdrawal
    withdrawal.save!

    %i[draft completed partially_failed].each do |status|
      withdrawal.status = status
      assert withdrawal.deletable?, "#{status} deveria poder ser excluída"
    end

    withdrawal.update_columns(status: StockWithdrawal.statuses[:processing], updated_at: 1.minute.ago)
    refute withdrawal.reload.deletable?
    withdrawal.update_columns(updated_at: 11.minutes.ago)
    assert withdrawal.reload.deletable?
  end

  test 'once lines were withdrawn only the notes stay editable in the header (date and reason are locked)' do
    withdrawal = build_withdrawal
    withdrawal.save!

    refute withdrawal.header_locked?
    withdrawal.status = :partially_failed
    assert withdrawal.header_locked?
  end

  test 'done lines are locked, pending and failed lines are not' do
    withdrawal = build_withdrawal(items: [[@product, @lagoa, 1], [@product, @bh, 1]])
    withdrawal.save!
    done, failed = withdrawal.items.to_a
    done.update!(status: :done)
    failed.update!(status: :failed)

    assert done.locked?
    refute failed.locked?
    assert_equal [failed], withdrawal.editable_items.to_a
    assert_equal [done], withdrawal.locked_items.to_a
  end
end
