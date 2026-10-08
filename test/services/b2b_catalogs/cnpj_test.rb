require 'test_helper'

class B2bCatalogs::CnpjTest < ActiveSupport::TestCase
  test 'valid accepts masked and plain CNPJs with correct check digits' do
    assert B2bCatalogs::Cnpj.valid?('25.405.327/0001-74')
    assert B2bCatalogs::Cnpj.valid?('25405327000174')
  end

  test 'valid rejects wrong check digits, repeated digits and wrong length' do
    refute B2bCatalogs::Cnpj.valid?('25.405.327/0001-75')
    refute B2bCatalogs::Cnpj.valid?('11111111111111')
    refute B2bCatalogs::Cnpj.valid?('123')
    refute B2bCatalogs::Cnpj.valid?(nil)
  end

  test 'format masks fourteen digits' do
    assert_equal '25.405.327/0001-74', B2bCatalogs::Cnpj.format('25405327000174')
  end
end
