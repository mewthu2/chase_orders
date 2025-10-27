class CreateMarketingCampaigns < ActiveRecord::Migration[7.2]
  def change
    create_table :marketing_campaigns do |t|
      t.string :name, null: false
      t.text :objective
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :users_per_week, default: 0
      t.integer :status, default: 0, null: false
      t.integer :campaign_type, default: 0, null: false
      t.integer :created_by_id
      t.timestamps
    end

    add_index :marketing_campaigns, :status
    add_index :marketing_campaigns, :campaign_type
    add_index :marketing_campaigns, :created_by_id
    add_index :marketing_campaigns, [:start_date, :end_date]
  end
end
