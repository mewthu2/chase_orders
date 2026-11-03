class AddSefazAndShopifyToFiscalNotes < ActiveRecord::Migration[7.2]
  def change
    add_reference :fiscal_notes, :order, foreign_key: true
    add_column :fiscal_notes, :shopify_order_name, :string
    add_column :fiscal_notes, :sefaz_status_code, :string
    add_column :fiscal_notes, :sefaz_message, :text
    add_column :fiscal_notes, :sefaz_receipt, :string
    add_column :fiscal_notes, :authorized_at, :datetime

    # Homologação e produção têm numerações independentes: testar não pode queimar número de produção.
    add_column :companies, :next_nfe_number_homologation, :integer, default: 1, null: false
    remove_index :fiscal_notes, [:company_id, :series, :number], unique: true
    add_index :fiscal_notes, [:company_id, :environment, :series, :number], unique: true,
                                                                              name: 'index_fiscal_notes_on_company_env_series_number'

    # Naturezas de operação no molde do Tiny: CFOP da regra geral e a tributação de ICMS, DIFAL, PIS e COFINS.
    create_table :operation_natures do |t|
      t.references :company, null: false, foreign_key: true
      t.string :description, null: false
      t.integer :kind, null: false, default: 0
      t.boolean :default_for_kind, null: false, default: false
      t.integer :purpose, null: false, default: 1
      t.boolean :final_consumer, null: false, default: true
      t.string :cfop, null: false
      t.string :cfop_interstate_non_contributor
      t.string :icms_situation, null: false, default: '00'
      t.decimal :icms_rate, precision: 5, scale: 2, null: false, default: 0
      t.boolean :difal, null: false, default: true
      t.json :uf_rates
      t.string :pis_cst, null: false, default: '01'
      t.decimal :pis_rate, precision: 6, scale: 4, null: false, default: 0
      t.string :cofins_cst, null: false, default: '01'
      t.decimal :cofins_rate, precision: 6, scale: 4, null: false, default: 0
      t.boolean :exclude_icms_from_pis_cofins_base, null: false, default: true
      t.text :notes
      t.text :fisco_notes
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_reference :fiscal_notes, :operation_nature, foreign_key: true
  end
end
