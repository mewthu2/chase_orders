class AddReceiverNameToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_orders, :receiver_name, :string
  end
end
