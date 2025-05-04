class AddTinyCreationDateToOrders < ActiveRecord::Migration[7.2]
  def change
    add_column :orders, :tiny_creation_date, :string, after: :tags
  end
end
