class AddShopifyAndStaffFieldsToOrders < ActiveRecord::Migration[7.2]
  def up
    add_column :orders, :staff_id, :string, after: :tiny_creation_date unless column_exists?(:orders, :staff_id)
    add_column :orders, :staff_name, :string, after: :staff_id unless column_exists?(:orders, :staff_name)
    add_column :orders, :shopify_creation_date, :datetime, after: :staff_name unless column_exists?(:orders, :shopify_creation_date)
    add_column :orders, :iglu_payments, :json, after: :shopify_creation_date unless column_exists?(:orders, :iglu_payments)
  end

  def down
    remove_column :orders, :iglu_payments if column_exists?(:orders, :iglu_payments)
    remove_column :orders, :shopify_creation_date if column_exists?(:orders, :shopify_creation_date)
    remove_column :orders, :staff_name if column_exists?(:orders, :staff_name)
    remove_column :orders, :staff_id if column_exists?(:orders, :staff_id)
  end
end
