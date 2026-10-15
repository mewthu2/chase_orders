class CreateCashbackUnifications < ActiveRecord::Migration[7.2]
  def change
    create_table :cashback_unifications do |t|
      t.references :user, null: false, foreign_key: true
      t.references :customer, null: false, foreign_key: true
      t.string :customer_gid, null: false
      t.string :code, null: false
      t.string :shopify_node_id
      t.string :status, null: false, default: 'draft'
      t.json :source_snapshots, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.decimal :minimum_purchase, precision: 12, scale: 2, null: false
      t.datetime :expires_at, null: false
      t.boolean :ownership_confirmed, null: false, default: false
      t.string :step
      t.text :error_message
      t.datetime :completed_at
      t.timestamps
    end
    add_index :cashback_unifications, :code, unique: true

    # A durable claim on each source prevents overlapping pairs across workers.
    create_table :cashback_unification_sources do |t|
      t.references :cashback_unification, null: false, foreign_key: true, index: { name: 'idx_cashback_sources_unification' }
      t.string :shopify_node_id, null: false
      t.timestamps
    end
    add_index :cashback_unification_sources, :shopify_node_id, unique: true, name: 'idx_cashback_sources_shopify_unique'

    reversible do |dir|
      dir.up do
        execute <<~SQL
          INSERT INTO screen_permissions (profile_id, screen_key, created_at, updated_at)
          SELECT id, 'cashback_unifications', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM profiles
          WHERE id = 2 AND NOT EXISTS (
            SELECT 1 FROM screen_permissions WHERE profile_id = 2 AND screen_key = 'cashback_unifications'
          )
        SQL
      end
      dir.down { execute "DELETE FROM screen_permissions WHERE screen_key = 'cashback_unifications'" }
    end
  end
end
