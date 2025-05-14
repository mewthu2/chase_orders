class AddTiny2IdToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :tiny_2_id, :string, after: :tiny_rj_id
    add_column :products, :stock_tiny_2, :string, after: :stock_rj
  end
end
