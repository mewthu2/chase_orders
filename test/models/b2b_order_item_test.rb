require 'test_helper'

class B2bOrderItemTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Teste Item', email: 'teste_item@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Item')
    @order = B2bOrder.create!(kind: :sale, user: @user, client: @client)
  end

  test 'discount defaults to zero' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 1, price: 10)
    assert_equal 0, item.discount
  end

  test 'discount cannot be negative' do
    item = @order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 10, discount: -1)
    refute item.valid?
    assert_includes item.errors[:discount], 'deve ser maior ou igual a 0'
  end

  test 'line_total subtracts the discount before multiplying by quantity' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 3, price: 10, discount: 2)
    assert_equal 24.0, item.line_total
  end

  test 'line_total never goes negative even if discount exceeds price' do
    item = @order.b2b_order_items.create!(sku: 'SKU1', quantity: 2, price: 5, discount: 20)
    assert_equal 0.0, item.line_total
  end
end
