class AddLastShopifySyncToStockCorrectionItems < ActiveRecord::Migration[7.2]
  def change
    add_column :stock_correction_items, :last_shopify_sync_at, :datetime
    add_column :stock_correction_items, :shopify_sync_status, :string, default: 'pending'
    add_column :stock_correction_items, :shopify_sync_error, :text
    
    add_index :stock_correction_items, :last_shopify_sync_at
    add_index :stock_correction_items, :shopify_sync_status
  end
end
