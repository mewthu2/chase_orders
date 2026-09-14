class SeedB2bScreenPermissions < ActiveRecord::Migration[7.2]
  def up
    execute <<-SQL
      INSERT INTO screen_permissions (profile_id, screen_key, created_at, updated_at) VALUES
        (1, 'b2b_orders', NOW(), NOW()),
        (1, 'transfer_locations', NOW(), NOW())
    SQL
  end

  def down
    execute <<-SQL
      DELETE FROM screen_permissions WHERE profile_id = 1 AND screen_key IN ('b2b_orders', 'transfer_locations')
    SQL
  end
end
