class AddCarrierToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_reference :b2b_orders, :carrier, null: true, foreign_key: true
  end
end
