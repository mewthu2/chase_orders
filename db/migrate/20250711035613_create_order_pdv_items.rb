class CreateOrderPdvItems < ActiveRecord::Migration[7.2]
  def change
    create_table :order_pdv_items do |t|
      t.references :order_pdv, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.string :sku, null: false
      t.string :product_name, null: false
      t.decimal :price, precision: 10, scale: 2, null: false
      t.integer :quantity, null: false
      t.decimal :total, precision: 10, scale: 2, null: false
      t.string :option1
      t.string :image_url

      t.timestamps
    end

    add_index :order_pdv_items, [:order_pdv_id, :product_id]
  end
end
