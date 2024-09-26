class RenameTinyProductIdAndAddTinyBhShoppingIdToProducts < ActiveRecord::Migration[6.1]
  def up
    rename_column :products, :tiny_product_id, :tiny_lagoa_seca_product_id

    add_column :products, :tiny_bh_shopping_id, :integer, after: :tiny_lagoa_seca_product_id
  end

  def down
    remove_column :products, :tiny_bh_shopping_id

    rename_column :products, :tiny_lagoa_seca_product_id, :tiny_product_id
  end
end
