require 'test_helper'

class FiscalFieldsTest < ActiveSupport::TestCase
  test 'products default to origin 0 and unit UN' do
    product = Product.new
    assert_equal 0, product.origin
    assert_equal 'UN', product.commercial_unit
  end

  test 'product fiscal validations only apply when the fields are filled' do
    assert Product.new(sku: 'A').valid?
    assert Product.new(sku: 'A', ncm: '61099000', cest: '2806100').valid?
    refute Product.new(sku: 'A', ncm: '6109').valid?
    refute Product.new(sku: 'A', ncm: '6109900A').valid?
    refute Product.new(sku: 'A', cest: '123').valid?
    refute Product.new(sku: 'A', origin: 9).valid?
    refute Product.new(sku: 'A', commercial_unit: '').valid?
  end

  test 'clients default to non-contributor IE indicator' do
    assert_equal 9, Client.new.ie_indicator
  end

  test 'client IE indicator only accepts 1, 2 or 9 and IBGE code has 7 digits when filled' do
    base = { responsible_name: 'Fulano', registration: '25.405.327/0001-74' }
    assert Client.new(base.merge(ie_indicator: 1, city_ibge_code: '3106200')).valid?
    refute Client.new(base.merge(ie_indicator: 3)).valid?
    refute Client.new(base.merge(city_ibge_code: '31062')).valid?
  end

  test 'transfer location IBGE code has 7 digits when filled' do
    attrs = { name: 'CD', registration: '25.405.327/0001-74', street: 'R', number: '1', neighbourhood: 'B',
              city: 'BH', state: 'MG', zip: '30000-000' }
    assert TransferLocation.new(attrs.merge(city_ibge_code: '3106200')).valid?
    refute TransferLocation.new(attrs.merge(city_ibge_code: '3106')).valid?
  end
end
