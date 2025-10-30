class ConvertProfileToMultipleProfiles < ActiveRecord::Migration[7.2]
  def up
    create_table :user_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.references :profile, null: false, foreign_key: true
      t.timestamps
    end

    add_index :user_profiles, [:user_id, :profile_id], unique: true

    execute <<-SQL
      INSERT INTO user_profiles (user_id, profile_id, created_at, updated_at)
      SELECT id, profile_id, NOW(), NOW()
      FROM users
      WHERE profile_id IS NOT NULL
    SQL

    remove_column :users, :profile_id
  end

  def down
    add_column :users, :profile_id, :integer

    execute <<-SQL
      UPDATE users u
      SET profile_id = (
        SELECT profile_id 
        FROM user_profiles 
        WHERE user_id = u.id 
        LIMIT 1
      )
    SQL

    drop_table :user_profiles
  end
end
