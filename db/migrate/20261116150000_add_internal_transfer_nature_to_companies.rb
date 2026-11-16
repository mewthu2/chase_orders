# Natureza da NF-e da Transferência Interna escolhida para cada empresa (em Transferência de Estoque →
# Configurações). Sem escolha, vale a natureza de transferência padrão da empresa.
class AddInternalTransferNatureToCompanies < ActiveRecord::Migration[8.0]
  def up
    return if column_exists?(:companies, :internal_transfer_nature_id)

    add_reference :companies, :internal_transfer_nature, null: true,
                  foreign_key: { to_table: :operation_natures, on_delete: :nullify }
  end

  def down
    remove_reference :companies, :internal_transfer_nature, foreign_key: { to_table: :operation_natures } if column_exists?(:companies, :internal_transfer_nature_id)
  end
end
