class AddCustomerToOrders < ActiveRecord::Migration[7.0]
  def change
    add_reference :orders, :customer, foreign_key: true, index: true
  end
end