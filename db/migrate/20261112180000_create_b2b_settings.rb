# Configuração do atacado: valor do frete fixo, aplicado quando o pedido escolhe "Frete fixo".
class CreateB2bSettings < ActiveRecord::Migration[8.0]
  def change
    create_table :b2b_settings, if_not_exists: true do |t|
      t.decimal :fixed_freight_value, precision: 12, scale: 2, default: 0, null: false
      t.timestamps
    end
    add_column :b2b_orders, :fixed_freight, :boolean, default: false, null: false, if_not_exists: true
  end
end
