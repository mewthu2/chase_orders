class AddStockFieldsForFortalezaAndPortoAlegre < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :stock_fortaleza_rio_mar, :integer, default: 0, after: :stock_rj
    add_column :products, :stock_porto_alegre_bourbon, :integer, default: 0, after: :stock_fortaleza_rio_mar
    add_column :products, :stock_eldorado_sp, :integer, default: 0, after: :stock_porto_alegre_bourbon
    
    add_index :products, :stock_fortaleza_rio_mar
    add_index :products, :stock_porto_alegre_bourbon
    add_index :products, :stock_eldorado_sp
  end
end
