class AddLocationToOrders < ActiveRecord::Migration[7.2]
  def up
    unless column_exists?(:orders, :location_id)
      add_column :orders, :location_id, :bigint, after: :id
      add_index  :orders, :location_id
      add_foreign_key :orders, :locations, column: :location_id
    end
  end

  def down
    if column_exists?(:orders, :location_id)
      remove_foreign_key :orders, column: :location_id
      remove_index :orders, :location_id
      remove_column :orders, :location_id
    end
  end
end
