# Forma de pagamento das notas já emitidas, lida do próprio XML (tPag do primeiro pagamento). Sem o XML,
# vale a do pedido de atacado (venda) ou "sem pagamento" (90). Só preenche o que está vazio e não
# derruba a migração se um XML não abrir: segura para rodar a qualquer momento e mais de uma vez.
class BackfillFiscalNotesPaymentMethod < ActiveRecord::Migration[8.0]
  SALE_CODES = { 'boleto' => '15', 'cartao' => '03', 'pix' => '17' }.freeze

  def up
    FiscalNote.reset_column_information
    FiscalNote.where(payment_method: nil).includes(:b2b_order, xml_attachment: :blob).find_each do |note|
      note.update_columns(payment_method: code_for(note))
    end
  end

  def down; end

  private

  def code_for(note)
    from_xml(note) || (note.b2b_order&.sale? && SALE_CODES[note.b2b_order.payment_method]) || '90'
  end

  def from_xml(note)
    return unless note.xml.attached?

    Nokogiri::XML(note.xml.download).remove_namespaces!.at('pag detPag tPag')&.text.presence
  rescue StandardError => e
    say "nota #{note.id}: XML não lido (#{e.class})"
    nil
  end
end
