class CreateCompanies < ActiveRecord::Migration[7.2]
  def change
    create_table :companies do |t|
      t.string :legal_name, null: false
      t.string :trade_name
      t.string :cnpj, null: false
      t.string :state_registration
      t.string :municipal_registration
      t.string :cnae
      t.integer :tax_regime, null: false, default: 1

      t.string :street, null: false
      t.string :number, null: false
      t.string :complement
      t.string :neighbourhood, null: false
      t.string :city, null: false
      t.string :city_ibge_code, null: false
      t.string :state, null: false
      t.string :zip, null: false
      t.string :phone
      t.string :email

      t.integer :environment, null: false, default: 2
      t.integer :nfe_series, null: false, default: 1
      t.integer :next_nfe_number, null: false, default: 1

      t.string :cfop_sale_in_state, null: false, default: '5102'
      t.string :cfop_sale_out_of_state, null: false, default: '6102'
      t.string :cfop_transfer_in_state, null: false, default: '5152'
      t.string :cfop_transfer_out_of_state, null: false, default: '6152'
      t.string :operation_nature_sale, null: false, default: 'Venda de mercadoria'
      t.string :operation_nature_transfer, null: false, default: 'Transferência de mercadoria'
      t.string :icms_situation, null: false, default: '102'
      t.string :pis_cst, null: false, default: '49'
      t.string :cofins_cst, null: false, default: '49'

      t.boolean :active, null: false, default: true

      t.text :certificate_password
      t.datetime :certificate_expires_at
      t.string :certificate_subject
      t.string :certificate_cnpj

      t.timestamps
    end

    add_index :companies, :cnpj, unique: true
  end
end
