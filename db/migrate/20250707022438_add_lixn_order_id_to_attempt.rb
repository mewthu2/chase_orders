class AddLixnOrderIdToAttempt < ActiveRecord::Migration[7.2]
  def change
    add_column :attempts, :lixn_order_id, :string
    add_column :attempts, :shopify_order_id, :string
  end
end
