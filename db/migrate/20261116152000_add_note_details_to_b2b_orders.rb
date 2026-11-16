# Dados da NF-e editáveis no pedido B2B (aba Nota fiscal) antes de a nota ser autorizada: informações
# complementares (sem elas, vale o texto da natureza) e transportadora com a modalidade do frete.
class AddNoteDetailsToB2bOrders < ActiveRecord::Migration[8.0]
  def up
    add_column :b2b_orders, :nf_additional_info, :text unless column_exists?(:b2b_orders, :nf_additional_info)
    add_column :b2b_orders, :nf_freight_mode, :string, limit: 1 unless column_exists?(:b2b_orders, :nf_freight_mode)
    return if column_exists?(:b2b_orders, :nf_carrier_id)

    add_reference :b2b_orders, :nf_carrier, null: true, foreign_key: { to_table: :carriers, on_delete: :nullify }
  end

  def down
    remove_reference :b2b_orders, :nf_carrier, foreign_key: { to_table: :carriers } if column_exists?(:b2b_orders, :nf_carrier_id)
    remove_column :b2b_orders, :nf_freight_mode if column_exists?(:b2b_orders, :nf_freight_mode)
    remove_column :b2b_orders, :nf_additional_info if column_exists?(:b2b_orders, :nf_additional_info)
  end
end
