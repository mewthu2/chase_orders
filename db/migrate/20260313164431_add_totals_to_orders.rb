class AddTotalsToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :current_total_price, :decimal, precision: 10, scale: 2
    add_column :orders, :current_total_discounts, :decimal, precision: 10, scale: 2
  end
end