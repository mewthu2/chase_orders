require 'test_helper'

class AttemptStockReservationTest < ActiveSupport::TestCase
  setup do
    StockReservation.create!(account: :b2c, tiny_order_id: '100', sku: 'LEG-A', quantity: 2)
    StockReservation.create!(account: :b2c, tiny_order_id: '100', sku: 'TOP-B', quantity: 1)
    StockReservation.create!(account: :b2b, tiny_order_id: '100', sku: 'LEG-A', quantity: 5)
  end

  test 'getting a Correios order number releases the reservation of that order right away' do
    attempt = Attempt.create!(kinds: :create_correios_order, status: :processing, tiny_order_id: 100)
    assert_equal 2, StockReservation.where(account: :b2c).count

    attempt.update!(order_correios_id: 25_135_290)

    assert_equal 0, StockReservation.where(account: :b2c).count
    assert_equal 1, StockReservation.where(account: :b2b).count, 'a reserva da outra conta não é afetada'
  end

  test 'a B2B creation marked success releases only the B2B reservation' do
    Attempt.create!(kinds: :create_correios_order_tiny2, status: :success, tiny_order_id: 100)

    assert_equal 0, StockReservation.where(account: :b2b).count
    assert_equal 2, StockReservation.where(account: :b2c).count
  end

  test 'a failed creation without a Correios number keeps the reservation' do
    Attempt.create!(kinds: :create_correios_order, status: :fail, tiny_order_id: 100, message: 'Produto sem estoque')

    assert_equal 2, StockReservation.where(account: :b2c).count
  end

  test 'other attempt kinds never touch reservations' do
    Attempt.create!(kinds: :emission_invoice, status: :success, tiny_order_id: 100, order_correios_id: 25_135_290)

    assert_equal 3, StockReservation.count
  end
end
