class CreateB2bOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_orders do |t|
      t.integer :kind, null: false
      t.integer :status, null: false, default: 0
      t.references :client, null: true, foreign_key: true
      t.references :transfer_location, null: true, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :carrier_name
      t.string :carrier_shipping_method
      t.integer :freight_paid_by
      t.decimal :freight_value, precision: 10, scale: 2
      t.string :tiny_reference_id
      t.string :tiny_reference_number
      t.text :error_message
      t.text :notes
      t.timestamps
    end
  end
end
