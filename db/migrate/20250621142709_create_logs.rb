class CreateLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :logs do |t|
      t.references :user, null: false, foreign_key: true
      t.string :resource_type, null: false
      t.string :resource_id
      t.string :action_type, null: false
      t.string :resource_name
      t.text :details
      t.text :old_values
      t.text :new_values
      t.string :ip_address
      t.string :user_agent
      t.text :error_message
      t.boolean :success, default: true
      t.timestamps
    end

    add_index :logs, :resource_type
    add_index :logs, :action_type
    add_index :logs, :resource_name
    add_index :logs, :success
    add_index :logs, :created_at
    add_index :logs, [:resource_type, :resource_id]
    add_index :logs, [:user_id, :resource_type]
  end
end