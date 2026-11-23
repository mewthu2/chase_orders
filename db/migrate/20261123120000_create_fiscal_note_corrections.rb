# Cartas de correção (CC-e, evento 110110) registradas na SEFAZ para uma NF-e autorizada. Cada carta nova
# substitui a anterior (nSeqEvento 1..20) e o procEventoNFe fica anexado em xml.
# Só tabela nova: segura para rodar a qualquer momento.
class CreateFiscalNoteCorrections < ActiveRecord::Migration[8.0]
  def up
    return if table_exists?(:fiscal_note_corrections)

    create_table :fiscal_note_corrections do |t|
      t.references :fiscal_note, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.text :correction, null: false
      t.string :protocol
      t.datetime :registered_at
      t.string :created_by
      t.string :sefaz_status_code
      t.text :sefaz_message
      t.timestamps
      t.index [:fiscal_note_id, :sequence], unique: true
    end
  end

  def down
    drop_table :fiscal_note_corrections if table_exists?(:fiscal_note_corrections)
  end
end
