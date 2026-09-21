class AddDiscountToB2bOrderItems < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_order_items, :discount, :decimal, precision: 10, scale: 2, null: false, default: 0
  end
end
