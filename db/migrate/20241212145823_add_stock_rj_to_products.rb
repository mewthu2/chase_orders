class AddStockRjToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :stock_rj, :integer, after: :stock_bh_shopping
  end
end
