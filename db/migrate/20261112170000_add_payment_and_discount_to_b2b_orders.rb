# Pedido do atacado: forma de pagamento (boleto, pix ou cartão) e desconto livre no total do pedido,
# em reais ou porcentagem (substitui o desconto manual por item).
class AddPaymentAndDiscountToB2bOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_orders, :payment_method, :string, if_not_exists: true
    add_column :b2b_orders, :order_discount, :decimal, precision: 12, scale: 2, default: 0, null: false, if_not_exists: true
    add_column :b2b_orders, :order_discount_type, :string, default: 'amount', null: false, if_not_exists: true
  end
end
