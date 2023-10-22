class AddOrderCorreiosIdToAttempts < ActiveRecord::Migration[7.0]
  def change
    add_column :attempts, :order_correios_id, :integer, after: :tiny_order_id
  end
end
