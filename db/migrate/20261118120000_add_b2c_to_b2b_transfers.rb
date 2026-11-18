# Transferência no sentido B2C → B2B: não vai ao Correios, só gera duas notas (transferência emitida pela filial
# B2C e remessa emitida pela filial B2B).
# - b2b_orders.transfer_direction: 0 = B2B → B2C (todos os pedidos de hoje), 1 = B2C → B2B;
# - b2b_settings: empresa e natureza de cada nota e destinatário padrão da remessa.
# Só colunas novas, com padrão ou opcionais: segura para rodar a qualquer momento.
class AddB2cToB2bTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_orders, :transfer_direction, :integer, default: 0, null: false unless column_exists?(:b2b_orders, :transfer_direction)
    add_column :b2b_settings, :b2c_to_b2b_issuer_company_id, :bigint unless column_exists?(:b2b_settings, :b2c_to_b2b_issuer_company_id)
    add_column :b2b_settings, :b2c_to_b2b_nature_id, :bigint unless column_exists?(:b2b_settings, :b2c_to_b2b_nature_id)
    add_column :b2b_settings, :b2c_to_b2b_remessa_issuer_company_id, :bigint unless column_exists?(:b2b_settings, :b2c_to_b2b_remessa_issuer_company_id)
    add_column :b2b_settings, :b2c_to_b2b_remessa_nature_id, :bigint unless column_exists?(:b2b_settings, :b2c_to_b2b_remessa_nature_id)
    add_column :b2b_settings, :b2c_to_b2b_remessa_recipient, :json unless column_exists?(:b2b_settings, :b2c_to_b2b_remessa_recipient)
  end
end
