class AddIntegrationStatusToStockCorrections < ActiveRecord::Migration[7.2]
  def change
    add_column :stock_corrections, :integration_started_at, :datetime
    add_column :stock_corrections, :integration_status, :string
    add_column :stock_corrections, :integration_error, :text
    
    add_index :stock_corrections, :integration_status
  end
end
