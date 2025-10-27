class CreateMarketingTasks < ActiveRecord::Migration[7.2]
  def change
    create_table :marketing_tasks do |t|
      t.references :marketing_campaign, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :lead_email
      t.string :lead_name
      t.string :lead_phone
      t.json :lead_data
      t.integer :status, default: 0, null: false
      t.boolean :converted, default: false
      t.string :order_number
      t.decimal :order_value, precision: 10, scale: 2
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :converted_at
      t.text :notes
      t.string :shopify_checkout_id
      t.timestamps
    end

    add_index :marketing_tasks, :status
    add_index :marketing_tasks, :converted
    add_index :marketing_tasks, :shopify_checkout_id
    add_index :marketing_tasks, :lead_email
    add_index :marketing_tasks, [:marketing_campaign_id, :status]
    add_index :marketing_tasks, [:user_id, :status]
  end
end
