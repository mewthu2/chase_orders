class AddMissingInventoryColumns < ActiveRecord::Migration[7.2]
  def change
    add_column :order_pdvs, :inventory_reservations, :text

    add_column :order_pdvs, :reservation_error, :text
    
    add_index :order_pdvs, :reservation_status
  end
end
