# Nota de transferência emitida ao enviar uma remessa da Transferência Interna.
class AddInternalTransferShipmentToFiscalNotes < ActiveRecord::Migration[7.2]
  def change
    add_reference :fiscal_notes, :internal_transfer_shipment, foreign_key: true, null: true, if_not_exists: true
  end
end
