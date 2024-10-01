class AddProductsToOrderItems < ActiveRecord::Migration[7.2]
  def change
    rename_column :order_items, :product_id, :tiny_product_id
    add_reference :order_items, :product, foreign_key: true, after: :order_id
  end
end
