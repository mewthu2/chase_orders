class CreateFiscalNotes < ActiveRecord::Migration[7.2]
  def change
    create_table :fiscal_notes do |t|
      t.references :company, null: false, foreign_key: true
      t.references :b2b_order, foreign_key: true
      t.integer :number, null: false
      t.integer :series, null: false
      t.string :access_key, limit: 44
      t.integer :environment, null: false, default: 2
      t.string :operation_nature
      t.string :cfop_summary
      t.integer :status, null: false, default: 0
      t.string :protocol
      t.decimal :total_value, precision: 12, scale: 2, null: false, default: 0
      t.text :error_message
      t.datetime :issued_at

      t.timestamps
    end

    add_index :fiscal_notes, [:company_id, :series, :number], unique: true
    add_index :fiscal_notes, :status
  end
end
