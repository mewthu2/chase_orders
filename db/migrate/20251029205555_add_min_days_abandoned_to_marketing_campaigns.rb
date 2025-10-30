class AddMinDaysAbandonedToMarketingCampaigns < ActiveRecord::Migration[7.2]
  def change
    add_column :marketing_campaigns, :min_days_abandoned, :integer, default: 0
  end
end
