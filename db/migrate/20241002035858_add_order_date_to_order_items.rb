class AddOrderDateToOrderItems < ActiveRecord::Migration[7.2]
  def change
    add_column :order_items, :order_date_bh_shopping, :date , after: :canceled
    add_column :order_items, :order_date_lagoa_seca, :date , after: :order_date_bh_shopping
  end
end
