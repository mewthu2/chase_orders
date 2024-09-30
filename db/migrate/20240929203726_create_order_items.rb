class CreateOrderItems < ActiveRecord::Migration[7.2]
  def change
    create_table :order_items do |t|
      t.references :order, null: false, foreign_key: true, index: true
      t.string :price
      t.integer :quantity
      t.integer :product_id
      t.string :sku
      t.boolean :canceled, default: false
      t.timestamps
    end
  end
end
