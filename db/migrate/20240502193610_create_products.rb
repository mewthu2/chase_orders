class CreateProducts < ActiveRecord::Migration[7.1]
  def up
    create_table :products do |t|
      t.string :sku
      t.string :tiny_product_id
      t.string :shopify_product_id
      t.string :shopify_inventory_item_id
      t.string :shopify_product_name
      t.string :cost
      t.timestamps
    end
  end

  def down
    drop_table :products
  end
end
