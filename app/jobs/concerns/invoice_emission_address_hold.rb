# Regra compartilhada pelos jobs de emissão de nota (B2C e B2B).
#
# O Tiny recusa a nota quando um campo do endereço da nota está vazio ("O campo "Bairro" não foi
# preenchido..."). Se o Honey já tem a correção desse pedido, ela não chega à nota (a API do Tiny
# não altera nota), então em vez de repetir o erro a cada execução o pedido fica aguardando a
# correção manual da nota no Tiny, com uma mensagem dizendo exatamente o que digitar.
module InvoiceEmissionAddressHold
  extend ActiveSupport::Concern

  ADDRESS_FIELD_ERROR = /O campo "(#{AddressCorrection::FIELDS.keys.join('|')})" não foi preenchido ou está inválido/i

  NOTA_EDIT_URL = 'https://erp.tiny.com.br/notas_fiscais#edit/'.freeze

  private

  # Pedidos que a emissão automática deve pular.
  def held_tiny_order_ids
    AddressCorrection.awaiting_tiny_fix.pluck(:tiny_order_id)
  end

  # Depois de uma emissão com erro: se for erro de endereço e houver correção com valor para o
  # campo, coloca o pedido em espera e troca a mensagem da tentativa. Devolve true se colocou.
  def hold_on_address_error(attempt, att, error_text)
    matched = error_text.to_s[ADDRESS_FIELD_ERROR, 1]
    field = AddressCorrection::FIELDS.keys.find { |name| name.casecmp?(matched.to_s) }
    return false unless field

    correction = AddressCorrection.for(att.tiny_order_id)
    value = correction&.value_for(field)
    return false unless value

    correction.hold!(error_text)
    attempt.update(message: hold_message(field, value, att.id_nota_fiscal))
    true
  end

  # Emissão bem-sucedida: se o pedido estava aguardando correção, libera.
  def release_hold_if_any(att)
    correction = AddressCorrection.for(att.tiny_order_id)
    correction.release! if correction&.awaiting_tiny_fix?
  end

  def hold_message(field, value, invoice_id)
    url = "#{ENV.fetch('TINY_NOTA_FISCAL_URL', NOTA_EDIT_URL)}#{invoice_id}"
    "O Tiny recusou o endereço da nota (campo \"#{field}\"). Correção do Honey: #{field} \"#{value}\". " \
      "Corrija a nota no Tiny (#{url}) e clique em \"Já corrigi no Tiny\"."
  end
end
