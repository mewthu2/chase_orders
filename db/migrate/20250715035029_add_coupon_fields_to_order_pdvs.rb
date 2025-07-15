class AddCouponFieldsToOrderPdvs < ActiveRecord::Migration[7.2]
  def change
    add_column :order_pdvs, :coupon_code, :string
    add_column :order_pdvs, :coupon_discount_amount, :decimal, precision: 10, scale: 2, default: 0
    
    add_index :order_pdvs, :coupon_code
  end
end
