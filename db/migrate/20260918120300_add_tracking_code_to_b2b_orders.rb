class AddTrackingCodeToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_orders, :tracking_code, :string
  end
end
