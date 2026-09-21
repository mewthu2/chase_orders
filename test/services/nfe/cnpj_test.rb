require 'test_helper'

class Nfe::CnpjTest < ActiveSupport::TestCase
  test 'accepts a valid CNPJ with or without mask' do
    assert Nfe::Cnpj.valid?('11.222.333/0001-81')
    assert Nfe::Cnpj.valid?('11222333000181')
  end

  test 'rejects wrong check digits, repeated digits and wrong length' do
    refute Nfe::Cnpj.valid?('11222333000182')
    refute Nfe::Cnpj.valid?('11111111111111')
    refute Nfe::Cnpj.valid?('123')
    refute Nfe::Cnpj.valid?(nil)
  end

  test 'formats and strips' do
    assert_equal '11.222.333/0001-81', Nfe::Cnpj.format('11222333000181')
    assert_equal '11222333000181', Nfe::Cnpj.digits('11.222.333/0001-81')
  end
end
