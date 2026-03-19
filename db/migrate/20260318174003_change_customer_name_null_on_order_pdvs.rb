class ChangeCustomerNameNullOnOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    change_column_null :order_pdvs, :customer_name, true
  end
end