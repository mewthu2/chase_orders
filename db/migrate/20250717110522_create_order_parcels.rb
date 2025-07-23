class CreateOrderParcels < ActiveRecord::Migration[7.2]
  def change
    create_table :order_parcels do |t|
      t.references :order_pdv, null: false, foreign_key: true
      t.string :payment_method, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :integration_id
      t.string :status, default: 'pending'
      t.text :notes
      t.json :payment_data
      t.datetime :paid_at
      t.datetime :failed_at

      t.timestamps
    end

    add_index :order_parcels, :integration_id
    add_index :order_parcels, :status
    add_index :order_parcels, [:order_pdv_id, :status]
  end
end
