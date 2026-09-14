class CreateB2bOrderItems < ActiveRecord::Migration[7.2]
  def change
    create_table :b2b_order_items do |t|
      t.references :b2b_order, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :name
      t.integer :quantity, null: false
      t.decimal :price, precision: 10, scale: 2, null: false
      t.timestamps
    end
  end
end
