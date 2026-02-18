class CreatePlannerOrders < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:planner_orders)
      create_table :planner_orders do |t|
        t.references :user, foreign_key: true
        t.string :reference, null: false
        t.integer :status, default: 0, null: false
        t.text :error_message
        t.datetime :transmitted_at

        t.timestamps
      end
    end

    add_index :planner_orders, :reference, unique: true unless index_exists?(:planner_orders, :reference)
    add_index :planner_orders, :status unless index_exists?(:planner_orders, :status)

    unless table_exists?(:planner_order_items)
      create_table :planner_order_items do |t|
        t.references :planner_order, null: false, foreign_key: true
        t.string :name, null: false
        t.string :sku, null: false
        t.integer :quantity, null: false

        t.timestamps
      end
    end

    add_index :planner_order_items, :sku unless index_exists?(:planner_order_items, :sku)
  end

  def down
    remove_index :planner_order_items, :sku if index_exists?(:planner_order_items, :sku)
    drop_table :planner_order_items if table_exists?(:planner_order_items)

    remove_index :planner_orders, :status if index_exists?(:planner_orders, :status)
    remove_index :planner_orders, :reference if index_exists?(:planner_orders, :reference)
    drop_table :planner_orders if table_exists?(:planner_orders)
  end
end
