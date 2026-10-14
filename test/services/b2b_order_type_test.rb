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

  test 'orders to Chase not yet sent are typed from the full Tiny order' do
    tiny = {
      '10' => { pedido: { obs: 'Abastecimento | MAO PROPRIA', cliente: { cpf_cnpj: '00.000.000/0001-00' } } },
      '11' => { pedido: { obs: '', marcadores: [{ marcador: { descricao: '(Transferencia b2c)' } }], cliente: { cpf_cnpj: '' } } }
    }
    lookups = []
    fake = ->(_token, id) { lookups << id.to_s; tiny[id.to_s]&.with_indifferent_access }

    types = Tiny::Orders.stub(:obtain_order, fake) do
      B2bOrderType.for_orders(%w[10 11 12], names: { '10' => 'CHASE BRASIL COMERCIO', '11' => 'Chase Brasil', '12' => 'Loja do Zé' })
    end

    assert_equal({ '10' => :store_supply, '11' => :b2c_transfer, '12' => :sale }, types)
    assert_equal %w[10 11], lookups, 'clientes que não são a Chase nem buscam o pedido no Tiny'
  end

  test 'labels' do
    assert_equal 'Abastecimento Loja', B2bOrderType.label(:store_supply)
    assert_equal 'Transferência B2B → B2C', B2bOrderType.label('b2c_transfer')
    assert_equal 'B2B Comum', B2bOrderType.label(:sale)
  end
end
