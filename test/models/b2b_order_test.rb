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

  test 'status defaults to aberto' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    assert order.aberto?
  end

  test 'sale order requires a client' do
    order = B2bOrder.new(kind: :sale, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:client], 'não pode ficar em branco'
  end

  test 'stock_transfer order requires a transfer_location' do
    order = B2bOrder.new(kind: :stock_transfer, user: @user)
    order.b2b_order_items.build(sku: 'ABC', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:transfer_location], 'não pode ficar em branco'
  end

  test 'order requires at least one item' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    refute order.valid?
    assert_includes order.errors[:base], 'Pedido precisa ter pelo menos um item'
  end

  test 'a fully filled sale order is valid' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 2, price: 10.5)
    assert order.valid?
  end

  test 'resendable? is true for any non-cancelled order without a tiny_reference_id' do
    order = B2bOrder.new(kind: :sale, user: @user, status: :aberto)
    assert order.resendable?

    order.status = :dados_incompletos
    assert order.resendable?

    order.status = :cancelado
    refute order.resendable?

    order.status = :aberto
    order.tiny_reference_id = '123'
    refute order.resendable?
  end

  test 'total sums the line totals of all items' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    order.b2b_order_items.build(sku: 'A', quantity: 2, price: 10, discount: 1)
    order.b2b_order_items.build(sku: 'B', quantity: 1, price: 5, discount: 0)
    order.save!
    assert_equal 23.0, order.total
  end

  test 'price_list defaults to standard' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client)
    assert order.standard?
  end

  test 'different_shipping_address requires the shipping address fields' do
    order = B2bOrder.new(kind: :sale, user: @user, client: @client, different_shipping_address: true)
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    refute order.valid?
    assert_includes order.errors[:shipping_street], 'não pode ficar em branco'
    assert_includes order.errors[:shipping_zip], 'não pode ficar em branco'
  end

  test 'different_shipping_address is valid once all fields are filled' do
    order = B2bOrder.new(
      kind: :sale, user: @user, client: @client, different_shipping_address: true,
      shipping_street: 'Rua X', shipping_number: '10', shipping_neighbourhood: 'Centro',
      shipping_city: 'BH', shipping_state: 'MG', shipping_zip: '30000-000'
    )
    order.b2b_order_items.build(sku: 'A', quantity: 1, price: 10)
    assert order.valid?
  end

  test 'freight_service only accepts the Correios Log services (or blank)' do
    base = { kind: :sale, user: @user, client: @client }
    B2bOrder::FREIGHT_SERVICES.each do |service|
      order = B2bOrder.new(base.merge(freight_service: service))
      order.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 1, price: 1)
      assert order.valid?, "#{service} deveria ser válido: #{order.errors.full_messages.to_sentence}"
    end
    blank = B2bOrder.new(base.merge(freight_service: ''))
    blank.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 1, price: 1)
    assert blank.valid?

    invalid = B2bOrder.new(base.merge(freight_service: 'FOGUETE EXPRESS'))
    invalid.b2b_order_items.build(sku: 'ABC', name: 'Produto', quantity: 1, price: 1)
    refute invalid.valid?
    assert_equal %w[SEDEX\ CORREIOS\ LOG+ PAC\ CORREIOS\ LOG+ SEDEX\ HOJE\ LOG+], B2bOrder::FREIGHT_SERVICES
  end
end
