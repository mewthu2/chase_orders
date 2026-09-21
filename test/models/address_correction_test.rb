require 'test_helper'

class AddressCorrectionTest < ActiveSupport::TestCase
  def correction(overrides = {})
    AddressCorrection.create!({ tiny_order_id: '919948777', endereco: 'Rua Prefeito Albino Cerutti Cella', numero: '543',
                                bairro: 'Centro', cep: '89.874-000', cidade: 'Maravilha', uf: 'SC' }.merge(overrides))
  end

  test 'starts without a hold' do
    refute correction.awaiting_tiny_fix?
  end

  test 'hold! marks it as waiting for the fix in Tiny and keeps the Tiny message' do
    record = correction

    record.hold!('O campo "Bairro" não foi preenchido ou está inválido')

    assert record.reload.awaiting_tiny_fix?
    assert_not_nil record.awaiting_tiny_fix_at
    assert_match(/Bairro/, record.awaiting_tiny_fix_message)
  end

  test 'release! clears the hold and remembers when it was fixed' do
    record = correction
    record.hold!('x')

    record.release!

    refute record.reload.awaiting_tiny_fix?
    assert_nil record.awaiting_tiny_fix_message
    assert_not_nil record.tiny_fixed_at
  end

  test 'awaiting_tiny_fix scope only lists held corrections' do
    held = correction(tiny_order_id: '1')
    correction(tiny_order_id: '2')
    held.hold!('x')

    assert_equal [held], AddressCorrection.awaiting_tiny_fix.to_a
  end

  test 'value_for maps the field name Tiny uses to the corrected value' do
    record = correction

    assert_equal 'Centro', record.value_for('Bairro')
    assert_equal 'Maravilha', record.value_for('Cidade')
    assert_equal 'SC', record.value_for('UF')
    assert_equal '89.874-000', record.value_for('CEP')
    assert_equal '543', record.value_for('Número')
    assert_equal 'Rua Prefeito Albino Cerutti Cella', record.value_for('Endereço')
    assert_nil record.value_for('Inexistente')
  end

  test 'value_for is nil when the correction has no value for that field' do
    assert_nil correction(bairro: '').value_for('Bairro')
  end

  test 'summary is a readable one-line address' do
    assert_equal 'Rua Prefeito Albino Cerutti Cella, 543 - Centro - Maravilha/SC - CEP 89.874-000', correction.summary
  end

  test 'fix_instructions tells which field to type in Tiny, taken from the stored Tiny error' do
    record = correction
    record.hold!('A nota fiscal não foi enviada, pois contêm erros O campo "Bairro" não foi preenchido ou está inválido')

    assert_equal 'Bairro', record.failing_field
    assert_equal 'Corrija na nota do Tiny: Bairro "Centro".', record.fix_instructions
  end

  test 'fix_instructions falls back to the whole address when the failing field is unknown' do
    record = correction
    record.hold!('erro qualquer')

    assert_nil record.failing_field
    assert_match(/Corrija o endereço da nota no Tiny: Rua Prefeito/, record.fix_instructions)
  end
end
