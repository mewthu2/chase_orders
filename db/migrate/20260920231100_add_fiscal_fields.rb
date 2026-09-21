class AddFiscalFields < ActiveRecord::Migration[7.2]
  def change
    change_table :products, bulk: true do |t|
      t.string :ncm
      t.string :cest
      t.integer :origin, null: false, default: 0
      t.string :commercial_unit, null: false, default: 'UN'
    end

    # 1 contribuinte, 2 isento, 9 não contribuinte (indIEDest da NF-e)
    change_table :clients, bulk: true do |t|
      t.string :city_ibge_code
      t.integer :ie_indicator, null: false, default: 9
    end

    add_column :transfer_locations, :city_ibge_code, :string
  end
end
