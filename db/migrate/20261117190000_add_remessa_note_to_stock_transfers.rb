# Nota de remessa do Abastecimento Lojas (ex.: CFOP 5905, remessa para o depósito do Correios, a CLI CONTAGEM):
# uma nota a mais por pedido, além da de transferência para a loja (que continua sendo a do Correios).
# - b2b_settings: empresa, natureza e destinatário padrão da remessa (nas Configurações do Abastecimento);
# - b2b_orders.remessa_recipient: destinatário só deste pedido (vazio = o padrão das configurações);
# - fiscal_notes.role: 'remessa' nas notas de remessa; vazio nas notas do pedido de sempre.
# Só colunas novas, todas opcionais: segura para rodar a qualquer momento.
class AddRemessaNoteToStockTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_settings, :remessa_issuer_company_id, :bigint unless column_exists?(:b2b_settings, :remessa_issuer_company_id)
    add_column :b2b_settings, :remessa_nature_id, :bigint unless column_exists?(:b2b_settings, :remessa_nature_id)
    add_column :b2b_settings, :remessa_recipient, :json unless column_exists?(:b2b_settings, :remessa_recipient)
    add_column :b2b_orders, :remessa_recipient, :json unless column_exists?(:b2b_orders, :remessa_recipient)
    add_column :fiscal_notes, :role, :string unless column_exists?(:fiscal_notes, :role)
    add_index :fiscal_notes, %i[b2b_order_id role] unless index_exists?(:fiscal_notes, %i[b2b_order_id role])
  end
end
