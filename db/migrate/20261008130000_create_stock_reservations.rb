class CreateStockReservations < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_reservations do |t|
      t.integer :account, null: false
      t.string :tiny_order_id, null: false
      t.string :tiny_order_number
      t.string :customer_name
      t.date :order_date
      t.string :sku, null: false
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 0
      t.timestamps
    end
    add_index :stock_reservations, [:account, :sku]
    add_index :stock_reservations, [:account, :tiny_order_id]

    create_table :stock_reservation_refreshes do |t|
      t.integer :account, null: false
      t.datetime :last_refreshed_at
      t.string :status, null: false, default: 'idle'
      t.string :message
      t.timestamps
    end
    add_index :stock_reservation_refreshes, :account, unique: true
  end
end
