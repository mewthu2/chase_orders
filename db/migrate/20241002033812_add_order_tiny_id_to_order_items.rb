class AddOrderTinyIdToOrderItems < ActiveRecord::Migration[7.2]
  def change
    add_column :order_items, :order_tiny_id, :integer, after: :tiny_product_id
  end
end
