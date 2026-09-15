require 'test_helper'

class CarrierTest < ActiveSupport::TestCase
  def valid_attrs
    {
      name: 'Jamef Transportes', registration: '25.405.327/0001-74',
      street: 'Rua Teste', number: '100', neighbourhood: 'Centro',
      city: 'Belo Horizonte', state: 'MG', zip: '30000-000'
    }
  end

  test 'valid with all required fields' do
    assert Carrier.new(valid_attrs).valid?
  end

  test 'invalid without a CNPJ' do
    carrier = Carrier.new(valid_attrs.merge(registration: ''))
    refute carrier.valid?
  end

  test 'invalid with a malformed CNPJ' do
    carrier = Carrier.new(valid_attrs.merge(registration: '123'))
    refute carrier.valid?
  end

  test 'cnpj_formatted formats the digits' do
    carrier = Carrier.new(valid_attrs.merge(registration: '25405327000174'))
    assert_equal '25.405.327/0001-74', carrier.cnpj_formatted
  end

  test 'active scope only returns active carriers' do
    active = Carrier.create!(valid_attrs)
    inactive = Carrier.create!(valid_attrs.merge(name: 'Inativa', active: false))
    assert_includes Carrier.active, active
    refute_includes Carrier.active, inactive
  end

  test 'transmitted? is false until the Tiny contact id and timestamp are set' do
    carrier = Carrier.create!(valid_attrs)
    refute carrier.transmitted?

    carrier.update!(tiny_contact_id: '123', transmitted_at: Time.current)
    assert carrier.transmitted?
  end

  test 'cannot be destroyed while it has b2b_orders' do
    carrier = Carrier.create!(valid_attrs)
    user = User.create!(name: 'Teste Carrier', email: 'teste_carrier@example.com', password: 'password123')
    B2bOrder.create!(kind: :sale, status: :draft, carrier: carrier, user: user)

    refute carrier.destroy
    assert_includes carrier.errors[:base], 'Não é possível excluir o registro pois existem registros dependentes'
  end
end
