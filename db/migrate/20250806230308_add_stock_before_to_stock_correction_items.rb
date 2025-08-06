class AddStockBeforeToStockCorrectionItems < ActiveRecord::Migration[7.2]
  def change
    add_column :stock_correction_items, :stock_before, :integer, default: 0
    add_index :stock_correction_items, :stock_before
  end
end