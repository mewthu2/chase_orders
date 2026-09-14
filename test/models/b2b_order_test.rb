require 'test_helper'

class B2bOrderTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(name: 'Teste B2B', email: 'teste_b2b@example.com', password: 'password123')
    @client = Client.create!(responsible_name: 'Cliente Teste')
    @location = TransferLocation.create!(
      name: 'CD Teste', registration: '25.405.327/0001-74',
      street: 'Rua Teste', number: '100', neighbourhood: 'Centro',
      city: 'Belo Horizonte', state: 'MG', zip: '30000-000'
    )
  end

  test 'draft order does not require client, transfer_location or items' do
    order = B2bOrder.new(kind: :sale, status: :draft, user: @user)
    assert order.valid?
  end

  test 'sale order requires a client once not draft' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:client], 'não pode ficar em branco'
  end

  test 'stock_transfer order requires a transfer_location once not draft' do
    order = B2bOrder.new(kind: :stock_transfer, status: :saved, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:transfer_location], 'não pode ficar em branco'
  end

  test 'non-draft order requires at least one item' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user, client: @client)
    refute order.valid?
    assert_includes order.errors[:base], 'Pedido precisa ter pelo menos um item'
  end

  test 'saved order is a valid full example' do
    order = B2bOrder.new(kind: :sale, status: :saved, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 2, price: 10.5)
    assert order.valid?
  end

  test 'transmittable? is true only for saved or error' do
    order = B2bOrder.new(kind: :sale, status: :draft, user: @user)
    refute order.transmittable?
    order.status = :saved
    assert order.transmittable?
    order.status = :error
    assert order.transmittable?
    order.status = :transmitted
    refute order.transmittable?
  end
end
