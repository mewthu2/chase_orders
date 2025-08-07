class AddDeletedAtToStockCorrections < ActiveRecord::Migration[7.2]
  def change
    add_column :stock_corrections, :deleted_at, :datetime
    add_index :stock_corrections, :deleted_at
  end
end