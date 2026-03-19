class AddTinyFieldsToOrderPdvs < ActiveRecord::Migration[7.1]
  def change
    add_column :order_pdvs, :tiny_order_id,     :string
    add_column :order_pdvs, :tiny_order_number, :string
    add_column :order_pdvs, :tiny_status,       :string
    add_column :order_pdvs, :tiny_integrated_at, :datetime
    add_column :order_pdvs, :tiny_error,        :text

    add_index :order_pdvs, :tiny_order_id
  end
end
