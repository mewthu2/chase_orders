class AddStockToProducts < ActiveRecord::Migration[7.2]
  def up
    add_column :products, :stock_lagoa_seca, :string
    add_column :products, :stock_bh_shopping, :string
    add_column :products, :tags, :string
  end

  def down
    remove_column :products, :tags
    remove_column :products, :stock_bh_shopping
    remove_column :products, :stock_lagoa_seca
  end
end
