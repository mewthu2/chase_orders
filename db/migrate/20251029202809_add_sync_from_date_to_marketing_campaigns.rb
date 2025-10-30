class AddSyncFromDateToMarketingCampaigns < ActiveRecord::Migration[7.2]
  def change
    add_column :marketing_campaigns, :sync_from_date, :date
    add_index :marketing_campaigns, :sync_from_date
  end
end
