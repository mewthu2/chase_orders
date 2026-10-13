require 'test_helper'

class AttemptCustomerNameTest < ActiveSupport::TestCase
  test 'reads the customer name from the stored params' do
    attempt = Attempt.new(params: { invoice: '1', nome: 'Camilla Covello', fone: '11' }.inspect)
    assert_equal 'Camilla Covello', attempt.customer_name
  end

  test 'keeps accents and quotes of the name' do
    attempt = Attempt.new(params: { nome: 'Loja "Zé" Ção #1' }.inspect)
    assert_equal 'Loja "Zé" Ção #1', attempt.customer_name
  end

  test 'understands the newer hash inspect format too' do
    assert_equal 'Joana Dárc', Attempt.new(params: '{invoice: "1", nome: "Joana Dárc"}').customer_name
  end

  test 'is nil without params or name' do
    assert_nil Attempt.new.customer_name
    assert_nil Attempt.new(params: { nome: '' }.inspect).customer_name
  end
end
