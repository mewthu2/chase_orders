class AddOrderDateRjToOrderItem < ActiveRecord::Migration[7.2]
  def change
    add_column :order_items, :order_date_rj, :date , after: :order_date_lagoa_seca
  end
end
