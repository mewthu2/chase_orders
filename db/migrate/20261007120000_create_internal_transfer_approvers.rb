class CreateInternalTransferApprovers < ActiveRecord::Migration[7.2]
  # O aprovador único (internal_transfer_configs.approver_id) vira uma lista de aprovadores.
  # Quem já era aprovador continua sendo; admins aprovam sempre, sem precisar estar na lista.
  def up
    create_table :internal_transfer_approvers do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end

    execute <<~SQL
      INSERT INTO internal_transfer_approvers (user_id, created_at, updated_at)
      SELECT DISTINCT approver_id, NOW(), NOW() FROM internal_transfer_configs WHERE approver_id IS NOT NULL
    SQL

    drop_table :internal_transfer_configs
  end

  def down
    create_table :internal_transfer_configs do |t|
      t.references :approver, foreign_key: { to_table: :users }
      t.timestamps
    end

    execute <<~SQL
      INSERT INTO internal_transfer_configs (approver_id, created_at, updated_at)
      SELECT user_id, NOW(), NOW() FROM internal_transfer_approvers ORDER BY id LIMIT 1
    SQL

    drop_table :internal_transfer_approvers
  end
end
