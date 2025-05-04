class AddShopifyOrderIdAndTagsToOrders < ActiveRecord::Migration[7.2]
  def up
    add_column :orders, :shopify_order_id, :string, after: :tiny_order_id
    add_column :orders, :tags, :string, after: :shopify_order_id
  end

  def down
    remove_column :orders, :shopify_order_id
    remove_column :orders, :tags
  end
end
