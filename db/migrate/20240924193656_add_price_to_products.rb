class AddPriceToProducts < ActiveRecord::Migration[7.2]
  def up
    add_column :products, :price, :string
    add_column :products, :compare_at_price, :string
    add_column :products, :vendor, :string
    add_column :products, :option1, :string
    add_column :products, :option2, :string
    add_column :products, :option3, :string
  end

  def down
    remove_column :products, :option3
    remove_column :products, :option2
    remove_column :products, :option1
    remove_column :products, :vendor
    remove_column :products, :compare_at_price
    remove_column :products, :price
  end
end
