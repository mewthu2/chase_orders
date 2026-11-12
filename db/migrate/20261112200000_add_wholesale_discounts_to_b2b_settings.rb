# Desconto do preço de atacado sobre o varejo: Seamless (nome do produto com "Seamless") e os demais.
class AddWholesaleDiscountsToB2bSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_settings, :seamless_discount_percent, :decimal, precision: 5, scale: 2, default: 60, null: false, if_not_exists: true
    add_column :b2b_settings, :default_discount_percent, :decimal, precision: 5, scale: 2, default: 56.6, null: false, if_not_exists: true
  end
end
