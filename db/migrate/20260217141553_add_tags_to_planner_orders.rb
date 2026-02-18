class AddTagsToPlannerOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :planner_orders, :tags, :text
  end
end
