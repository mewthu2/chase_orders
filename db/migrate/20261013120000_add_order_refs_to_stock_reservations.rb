class AddOrderRefsToStockReservations < ActiveRecord::Migration[7.2]
  def change
    add_column :stock_reservations, :ecommerce_number, :string
    add_column :stock_reservations, :invoice_id, :string
  end
end
