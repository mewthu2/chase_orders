class AddTinyRjIdToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :tiny_rj_id, :integer, after: :tiny_bh_shopping_id
  end
end
