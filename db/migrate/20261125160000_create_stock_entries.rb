# Notas fiscais de entrada (XML de compra) e a colocação do estoque nos depósitos do Correios (Log02 e Log03),
# com a nota de remessa de cada lado. Só registro e notas: não mexe em estoque do Shopify nem do Correios.
class CreateStockEntries < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:stock_entries)
      create_table :stock_entries do |t|
        t.references :company, foreign_key: true
        t.string :access_key, limit: 44, null: false
        t.integer :number, null: false
        t.integer :series
        t.string :supplier_name
        t.string :supplier_cnpj, limit: 20
        t.string :supplier_state, limit: 2
        t.string :recipient_cnpj, limit: 20
        t.string :nature_text
        t.datetime :issued_at
        t.decimal :total_value, precision: 14, scale: 2, default: 0, null: false
        t.decimal :products_value, precision: 14, scale: 2, default: 0, null: false
        t.boolean :authorized, default: false, null: false
        t.references :created_by, foreign_key: { to_table: :users }
        t.timestamps
      end
      add_index :stock_entries, :access_key, unique: true
    end

    unless table_exists?(:stock_entry_items)
      create_table :stock_entry_items do |t|
        t.references :stock_entry, null: false, foreign_key: true
        t.integer :position, null: false
        t.string :sku, null: false
        t.string :ean
        t.string :description
        t.string :ncm, limit: 10
        t.string :cest, limit: 10
        t.integer :origin
        t.string :cfop, limit: 4
        t.string :unit, limit: 10
        t.decimal :quantity, precision: 14, scale: 4, null: false
        t.decimal :unit_price, precision: 16, scale: 6, default: 0, null: false
        t.decimal :total, precision: 14, scale: 2, default: 0, null: false
        t.timestamps
      end
      add_index :stock_entry_items, %i[stock_entry_id sku]
    end

    unless table_exists?(:stock_placements)
      create_table :stock_placements do |t|
        t.references :stock_entry, null: false, foreign_key: true
        t.string :side, null: false, limit: 10
        t.json :items, null: false
        t.string :csv_filename
        t.references :uploaded_by, foreign_key: { to_table: :users }
        # Nota de remessa gerada com a conferência divergente: quem marcou "estou ciente" e quando.
        t.references :divergence_acknowledged_by, foreign_key: { to_table: :users }
        t.datetime :divergence_acknowledged_at
        t.timestamps
      end
      add_index :stock_placements, %i[stock_entry_id side], unique: true
    end

    unless table_exists?(:stock_placement_configs)
      create_table :stock_placement_configs do |t|
        t.string :side, null: false, limit: 10
        t.references :company, foreign_key: true
        t.references :operation_nature, foreign_key: true
        t.json :recipient
        t.timestamps
      end
      add_index :stock_placement_configs, :side, unique: true
    end

    add_reference :fiscal_notes, :stock_placement, foreign_key: true unless column_exists?(:fiscal_notes, :stock_placement_id)
  end
end
