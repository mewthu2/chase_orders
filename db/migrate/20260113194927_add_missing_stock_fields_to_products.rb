class AddMissingStockFieldsToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :stock_shopping_analia_franco, :integer
    add_column :products, :stock_iguatemi_campinas, :integer
  end
end
