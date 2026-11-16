# Cancelamento da NF-e na SEFAZ (evento 110111): motivo, protocolo do evento, quando e quem cancelou.
# O XML do evento homologado (procEventoNFe) fica no anexo cancel_xml.
class AddCancellationToFiscalNotes < ActiveRecord::Migration[8.0]
  def up
    add_column :fiscal_notes, :cancel_reason, :text unless column_exists?(:fiscal_notes, :cancel_reason)
    add_column :fiscal_notes, :cancel_protocol, :string unless column_exists?(:fiscal_notes, :cancel_protocol)
    add_column :fiscal_notes, :canceled_at, :datetime unless column_exists?(:fiscal_notes, :canceled_at)
    add_column :fiscal_notes, :canceled_by, :string unless column_exists?(:fiscal_notes, :canceled_by)
  end

  def down
    %i[canceled_by canceled_at cancel_protocol cancel_reason].each do |column|
      remove_column :fiscal_notes, column if column_exists?(:fiscal_notes, column)
    end
  end
end
