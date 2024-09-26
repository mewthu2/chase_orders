class AddOrderCorreiosIdToAttempts < ActiveRecord::Migration[7.0]
  def up
    add_column :attempts, :order_correios_id, :integer
  end

  def down
    remove_column :attempts, :order_correios_id
  end
end
