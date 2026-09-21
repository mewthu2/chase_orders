require 'test_helper'

class TransferLocationTest < ActiveSupport::TestCase
  def valid_attrs
    {
      name: 'CD Teste', registration: '25.405.327/0001-74',
      street: 'Rua Teste', number: '100', neighbourhood: 'Centro',
      city: 'Belo Horizonte', state: 'MG', zip: '30000-000'
    }
  end

  test 'valid with all required fields' do
    assert TransferLocation.new(valid_attrs).valid?
  end

  test 'invalid without a CNPJ' do
    location = TransferLocation.new(valid_attrs.merge(registration: ''))
    refute location.valid?
  end

  test 'invalid with a malformed CNPJ' do
    location = TransferLocation.new(valid_attrs.merge(registration: '123'))
    refute location.valid?
  end

  test 'cnpj_formatted formats the digits' do
    location = TransferLocation.new(valid_attrs.merge(registration: '25405327000174'))
    assert_equal '25.405.327/0001-74', location.cnpj_formatted
  end

  test 'active scope only returns active locations' do
    active = TransferLocation.create!(valid_attrs)
    inactive = TransferLocation.create!(valid_attrs.merge(name: 'Inativo', active: false))
    assert_includes TransferLocation.active, active
    refute_includes TransferLocation.active, inactive
  end

  test 'cannot be destroyed while it has b2b_orders' do
    location = TransferLocation.create!(valid_attrs)
    user = User.create!(name: 'Teste TL', email: 'teste_tl@example.com', password: 'password123')
    order = B2bOrder.new(kind: :stock_transfer, transfer_location: location, user: user)
    order.b2b_order_items.build(sku: 'SKU1', quantity: 1, price: 1)
    order.save!

    refute location.destroy
    assert_includes location.errors[:base], 'Não é possível excluir o registro pois existem registros dependentes'
  end
end
