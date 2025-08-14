class AddIndexToAttemptsOnTinyOrderId < ActiveRecord::Migration[7.2]
  def change
    add_index :attempts, :tiny_order_id
  end
end