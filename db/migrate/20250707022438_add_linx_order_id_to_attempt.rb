class AddLinxOrderIdToAttempt < ActiveRecord::Migration[7.2]
  def change
    add_column :attempts, :linx_order_id, :string
    add_column :attempts, :shopify_order_id, :string
  end
end
