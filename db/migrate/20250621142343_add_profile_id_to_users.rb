class AddProfileIdToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :profile_id, :integer, default: 2
    add_index :users, :profile_id
  end
end