require 'test_helper'

class StockReservationTest < ActiveSupport::TestCase
  def reserve(account, sku, quantity, order_id: '1')
    StockReservation.create!(account:, tiny_order_id: order_id, sku:, quantity:)
  end

  test 'reserved_for sums quantities of the account only' do
    reserve(:b2b, 'LEG-A', 2, order_id: '1')
    reserve(:b2b, 'LEG-A', 2, order_id: '2')
    reserve(:b2c, 'LEG-A', 5, order_id: '3')

    assert_equal 4, StockReservation.reserved_for('LEG-A', account: :b2b)
    assert_equal 5, StockReservation.reserved_for('LEG-A', account: :b2c)
  end

  test 'sku is stored upcased and looked up case-insensitively' do
    reserve(:b2b, ' leg-a ', 1)

    assert_equal 'LEG-A', StockReservation.last.sku
    assert_equal 1, StockReservation.reserved_for('leg-a', account: :b2b)
  end

  test 'reserved_for is zero when nothing is reserved' do
    assert_equal 0, StockReservation.reserved_for('NONE', account: :b2b)
  end

  test 'reserved_for can leave out the reservation of one tiny order' do
    reserve(:b2b, 'LEG-A', 2, order_id: '77')
    reserve(:b2b, 'LEG-A', 1, order_id: '88')

    assert_equal 1, StockReservation.reserved_for('LEG-A', account: :b2b, exclude_tiny_order_id: '77')
    assert_equal 3, StockReservation.reserved_for('LEG-A', account: :b2b, exclude_tiny_order_id: nil)
  end
end
