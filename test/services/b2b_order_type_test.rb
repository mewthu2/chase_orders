require 'test_helper'
require 'minitest/mock'

# Tipo dos pedidos do Tiny B2B nas telas do Correios B2B.
class B2bOrderTypeTest < ActiveSupport::TestCase
  def setup
    ENV['TOKEN_TINY2_PRODUCTION'] = 'fake-token'
    @store = TransferLocation.create!(name: 'Loja Savassi', registration: '25.405.327/0005-06', street: 'Rua A', number: '1',
                                      neighbourhood: 'Savassi', city: 'Belo Horizonte', state: 'MG', zip: '30140-000')
  end

  def created(tiny_order_id, **params)
    Attempt.create!(kinds: :create_correios_order_tiny2, tiny_order_id:, params: { nome: 'Cliente', **params }.inspect)
  end

  test 'orders created in Honey take their kind' do
    user = User.create!(name: 'Tipo B2B', email: 'tipo_b2b@example.com', password: 'password123')
    order = B2bOrder.new(kind: :b2c_transfer, user:, price_list: :transfer, tiny_reference_id: '777')
    order.b2b_order_items.build(sku: 'LEG-1', name: 'Legging', quantity: 1, price: 10)
    order.save!

    assert_equal({ '777' => :b2c_transfer }, B2bOrderType.for_orders([777]))
  end

  test 'stock transfers created in Honey are store supply, old ones (nota fiscal) are ignored' do
    user = User.create!(name: 'Tipo Abast', email: 'tipo_abast@example.com', password: 'password123')
    [%w[90000777 1900], %w[555 555]].each do |id, number|
      order = B2bOrder.new(kind: :stock_transfer, user:, transfer_location: @store, price_list: :transfer,
                           tiny_reference_id: id, tiny_reference_number: number)
      order.b2b_order_items.build(sku: 'LEG-1', name: 'Legging', quantity: 1, price: 10)
      order.save!
    end

    assert_equal({ '90000777' => :store_supply, '555' => :sale }, B2bOrderType.for_orders(%w[90000777 555]))
  end

  test 'orders sent to the Correios are typed by the recipient CNPJ and hand delivery' do
    created(1, cpf_cnpj: '25405327000336')
    created(2, cpf_cnpj: '25405327000506')
    created(3, cpf_cnpj: '11222333000144', mao_propria: true)
    created(4, cpf_cnpj: '11222333000144')

    types = B2bOrderType.for_orders([1, 2, 3, 4])

    assert_equal :b2c_transfer, types['1']
    assert_equal :store_supply, types['2']
    assert_equal :store_supply, types['3']
    assert_equal :sale, types['4']
  end

  test 'the Tiny 2 is no longer asked: untyped orders are plain B2B' do
    lookups = []
    types = Tiny::Orders.stub(:obtain_order, ->(*args) { lookups << args }) do
      B2bOrderType.for_orders(%w[10 11], names: { '10' => 'CHASE BRASIL COMERCIO' })
    end

    assert_equal({ '10' => :sale, '11' => :sale }, types)
    assert_empty lookups
  end

  test 'labels' do
    assert_equal 'Abastecimento Loja', B2bOrderType.label(:store_supply)
    assert_equal 'Transferência B2B → B2C', B2bOrderType.label('b2c_transfer')
    assert_equal 'B2B Comum', B2bOrderType.label(:sale)
  end
end
