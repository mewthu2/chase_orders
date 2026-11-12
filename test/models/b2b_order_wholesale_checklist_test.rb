require 'test_helper'

class B2bOrderWholesaleChecklistTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Checklist', email: 'checklist@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Checklist', registration: '25.405.327/0001-74')
  end

  def order(**attrs)
    o = B2bOrder.new({ kind: :sale, user: @user, client: @client, payment_method: 'pix' }.merge(attrs))
    o.b2b_order_items.build(sku: 'A', name: 'A', quantity: 2, price: 50) # 100,00
    o
  end

  test 'the free discount works in reais and in percent and comes off the total' do
    assert_equal 15, order(order_discount: 15).discount_amount
    assert_equal 85, order(order_discount: 15).total
    assert_equal 12.5, order(order_discount: 12.5, order_discount_type: 'percent').discount_amount
  end

  test 'the discount cannot exceed the items nor 100%' do
    assert_not order(order_discount: 150).valid?
    assert_not order(order_discount: 101, order_discount_type: 'percent').valid?
    assert order(order_discount: 100, order_discount_type: 'percent').valid?
  end

  test 'the payment is required when the form asks for it, and only boleto, pix or cartão' do
    assert order(payment_method: nil).valid?
    assert_not order(payment_method: nil, require_payment: true).valid?
    assert_not order(payment_method: 'dinheiro').valid?
    assert order(payment_method: 'cartao', require_payment: true).valid?
  end
end
