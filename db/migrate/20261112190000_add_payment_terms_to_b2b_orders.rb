# Condição de pagamento do atacado (boleto ou cartão): dias de vencimento de cada parcela, como no Tiny ("30 60 90").
class AddPaymentTermsToB2bOrders < ActiveRecord::Migration[8.0]
  def change
    add_column :b2b_orders, :payment_terms, :string, if_not_exists: true
  end
end
