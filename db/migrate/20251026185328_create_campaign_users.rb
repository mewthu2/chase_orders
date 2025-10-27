class CreateCampaignUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :campaign_users do |t|
      t.references :marketing_campaign, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :tasks_assigned, default: 0
      t.integer :tasks_completed, default: 0
      t.integer :tasks_converted, default: 0
      t.timestamps
    end

    add_index :campaign_users, [:marketing_campaign_id, :user_id], unique: true, name: 'index_campaign_users_on_campaign_and_user'
  end
end
