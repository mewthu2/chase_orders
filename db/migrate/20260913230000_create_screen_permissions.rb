class CreateScreenPermissions < ActiveRecord::Migration[7.2]
  def up
    create_table :screen_permissions do |t|
      t.references :profile, null: false, foreign_key: true
      t.string :screen_key, null: false
      t.timestamps
    end
    add_index :screen_permissions, [:profile_id, :screen_key], unique: true

    # Seed today's real access so no profile loses a screen on deploy.
    # 1=Admin, 2=Gerente, 3=Vendedor, 5=Admin Marketing, 6=Agente Marketing
    execute <<-SQL
      INSERT INTO screen_permissions (profile_id, screen_key, created_at, updated_at) VALUES
        (1, 'users_management', NOW(), NOW()),
        (1, 'orders', NOW(), NOW()),
        (5, 'orders', NOW(), NOW()),
        (6, 'orders', NOW(), NOW()),
        (1, 'customers', NOW(), NOW()),
        (5, 'customers', NOW(), NOW()),
        (6, 'customers', NOW(), NOW()),
        (1, 'discounts', NOW(), NOW()),
        (2, 'discounts', NOW(), NOW()),
        (1, 'logs', NOW(), NOW()),
        (1, 'dashboard_correios', NOW(), NOW()),
        (1, 'marketing_campaigns', NOW(), NOW()),
        (5, 'marketing_campaigns', NOW(), NOW()),
        (1, 'marketing_tasks', NOW(), NOW()),
        (5, 'marketing_tasks', NOW(), NOW()),
        (6, 'marketing_tasks', NOW(), NOW())
    SQL
  end

  def down
    drop_table :screen_permissions
  end
end
