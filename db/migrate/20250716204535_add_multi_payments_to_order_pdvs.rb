class AddMultiPaymentsToOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    add_column :order_pdvs, :multi_payments, :text
    
    add_index :order_pdvs, :payment_method
  end
end
