class AddLocationToStockCorrections < ActiveRecord::Migration[7.2]
  def up
    add_reference :stock_corrections, :location, foreign_key: true
  end

  def down
    remove_foreign_key :stock_corrections, :locations
    remove_column :stock_corrections, :location_id
  end
end
