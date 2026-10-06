class AddApprovalToInternalTransfers < ActiveRecord::Migration[7.2]
  # Toda transferência interna nasce aguardando aprovação do aprovador configurado (um só, para o
  # sistema todo); nada é reservado no Shopify antes disso. As que já existem entram aprovadas,
  # para não travar o que já está em andamento.
  def change
    create_table :internal_transfer_configs do |t|
      t.references :approver, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_column :internal_transfers, :approval_status, :integer, null: false, default: 0
    add_reference :internal_transfers, :reviewed_by, foreign_key: { to_table: :users }
    add_column :internal_transfers, :reviewed_at, :datetime
    add_column :internal_transfers, :rejection_reason, :text

    reversible do |dir|
      dir.up { execute 'UPDATE internal_transfers SET approval_status = 1' }
    end
  end
end
