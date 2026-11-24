require 'test_helper'

class AttemptParamsTextTest < ActiveSupport::TestCase
  PARAMS = { invoice: '123', numero_ecommerce: 'B2C-9', nome: 'Ana Souza',
             itens: [{ codigo: 'SKU-1', quantidade: '2' }, { codigo: 'SKU-10', quantidade: '5' }] }.freeze
  OLD_FORMAT = '{:invoice=>"123", :numero_ecommerce=>"B2C-9", :nome=>"Ana Souza", ' \
               ':itens=>[{:codigo=>"SKU-1", :quantidade=>"2"}, {:codigo=>"SKU-10", :quantidade=>"5"}]}'.freeze

  test 'reads the text saved by the current Ruby (what Attempt#params holds after saving a Hash)' do
    text = Attempt.new(params: PARAMS).params

    assert_equal '123', AttemptParamsText.value(text, :invoice)
    assert_equal 'B2C-9', AttemptParamsText.value(text, :numero_ecommerce)
    assert_equal 'Ana Souza', AttemptParamsText.value(text, :nome)
    assert_equal '2', AttemptParamsText.item_quantity(text, 'SKU-1')
    assert_equal '5', AttemptParamsText.item_quantity(text, 'SKU-10')
  end

  test 'still reads attempts saved before Ruby 3.4 (:key=>"value")' do
    assert_equal '123', AttemptParamsText.value(OLD_FORMAT, :invoice)
    assert_equal 'Ana Souza', AttemptParamsText.value(OLD_FORMAT, 'nome')
    assert_equal '5', AttemptParamsText.item_quantity(OLD_FORMAT, 'SKU-10')
  end

  test 'a key is not confused with a longer key that ends with it, and missing data is nil / 0' do
    text = '{numero_ecommerce: "B2C-9"}'

    assert_nil AttemptParamsText.value(text, :ecommerce)
    assert_nil AttemptParamsText.value(nil, :invoice)
    assert_equal '0', AttemptParamsText.item_quantity(OLD_FORMAT, 'SKU-404')
  end
end
