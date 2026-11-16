# Empresa emissora e natureza da NF-e de cada tipo de transferência do Log02, escolhidas em
# Abastecimento Lojas → Configurações e Transferência B2B → B2C → Configurações. Sem escolha, valem a
# empresa da Configuração do atacado e a natureza de transferência de antes (transfer_nature_id).
class AddTransferNoteSettingsToB2bSettings < ActiveRecord::Migration[8.0]
  REFS = { supply_issuer_company: :companies, b2c_issuer_company: :companies,
           supply_nature: :operation_natures, b2c_nature: :operation_natures }.freeze

  def up
    REFS.each do |ref, table|
      next if column_exists?(:b2b_settings, "#{ref}_id")

      add_reference :b2b_settings, ref, null: true, foreign_key: { to_table: table, on_delete: :nullify }
    end
  end

  def down
    REFS.each do |ref, table|
      remove_reference :b2b_settings, ref, foreign_key: { to_table: table } if column_exists?(:b2b_settings, "#{ref}_id")
    end
  end
end
