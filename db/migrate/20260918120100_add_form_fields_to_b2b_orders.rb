class AddFormFieldsToB2bOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :b2b_orders, :salesperson_name, :string
    add_column :b2b_orders, :price_list, :integer, null: false, default: 0
    add_column :b2b_orders, :different_shipping_address, :boolean, null: false, default: false
    add_column :b2b_orders, :shipping_street, :string
    add_column :b2b_orders, :shipping_number, :string
    add_column :b2b_orders, :shipping_complement, :string
    add_column :b2b_orders, :shipping_neighbourhood, :string
    add_column :b2b_orders, :shipping_city, :string
    add_column :b2b_orders, :shipping_state, :string
    add_column :b2b_orders, :shipping_zip, :string
  end
end
