class CreateStockSyncConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_sync_configs do |t|
      t.boolean :enabled, default: false, null: false
      t.text :days_of_week, null: false
      t.text :hours, null: false  
      t.datetime :last_execution
      t.timestamps
    end
  end
end
