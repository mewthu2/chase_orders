# Pedidos do atacado, abastecimento e transferência B2C rodam no Log02 direto do Honey, sem o Tiny:
# - attempts.b2b_order_id: tentativas (criação no Correios, XML, rastreio) do pedido do Honey;
# - b2b_orders.correios_order_id / xml_sent_at / log_ignored: em que ponto o pedido está no Log02;
# - b2b_settings: empresa que emite a NF-e e as naturezas (venda e transferência).
class AddHoneyLog02Flow < ActiveRecord::Migration[8.0]
  def change
    add_column :attempts, :b2b_order_id, :bigint, if_not_exists: true
    add_index :attempts, :b2b_order_id, if_not_exists: true

    add_column :b2b_orders, :correios_order_id, :bigint, if_not_exists: true
    add_column :b2b_orders, :xml_sent_at, :datetime, if_not_exists: true
    add_column :b2b_orders, :log_ignored, :boolean, default: false, null: false, if_not_exists: true

    add_column :b2b_settings, :issuer_company_id, :bigint, if_not_exists: true
    add_column :b2b_settings, :sale_nature_id, :bigint, if_not_exists: true
    add_column :b2b_settings, :transfer_nature_id, :bigint, if_not_exists: true
  end
end
