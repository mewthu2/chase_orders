class AllowNullPaymentMethodOnOrderPdvs < ActiveRecord::Migration[7.2]
  def up
    change_column :order_pdvs, :payment_method, :string, null: true, default: nil
    change_column :order_pdvs, :customer_name,  :string, null: true
    change_column :order_pdvs, :customer_email, :string, null: true
    change_column :order_pdvs, :customer_phone, :string, null: true
    change_column :order_pdvs, :customer_cpf,   :string, null: true
    change_column :order_pdvs, :address1,        :string, null: true
    change_column :order_pdvs, :city,            :string, null: true
    change_column :order_pdvs, :state,           :string, null: true
    change_column :order_pdvs, :zip,             :string, null: true
  end

  def down
    change_column :order_pdvs, :payment_method, :string, null: false
  end
end
