# - b2b_settings.b2b_to_b2c_remessa_*: nota de remessa da transferência B2B → B2C (a filial B2C manda para o
#   depósito do Correios), com empresa, natureza e destinatário padrão próprios, como no B2C → B2B;
# - fiscal_notes.payment_method: forma de pagamento da nota (código tPag da NF-e: 03 crédito, 15 boleto,
#   17 Pix, 90 sem pagamento...), para a coluna da lista de notas sem abrir o XML.
# Só colunas novas e opcionais: segura para rodar a qualquer momento.
class AddB2bToB2cRemessaAndNotePayment < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_settings, :b2b_to_b2c_remessa_issuer_company_id, :bigint unless column_exists?(:b2b_settings, :b2b_to_b2c_remessa_issuer_company_id)
    add_column :b2b_settings, :b2b_to_b2c_remessa_nature_id, :bigint unless column_exists?(:b2b_settings, :b2b_to_b2c_remessa_nature_id)
    add_column :b2b_settings, :b2b_to_b2c_remessa_recipient, :json unless column_exists?(:b2b_settings, :b2b_to_b2c_remessa_recipient)
    add_column :fiscal_notes, :payment_method, :string, limit: 2 unless column_exists?(:fiscal_notes, :payment_method)
  end
end
