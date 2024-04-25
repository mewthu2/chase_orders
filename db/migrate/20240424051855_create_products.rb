class CreateProducts < ActiveRecord::Migration[7.0]
  def change
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
end
