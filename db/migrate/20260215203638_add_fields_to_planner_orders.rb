class AddFieldsToPlannerOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :planner_orders, :tiny_note_number, :string
    add_column :planner_orders, :tiny_response, :text
    add_column :planner_orders, :csv_filename, :string
    add_column :planner_orders, :order_number, :string
  end
end
