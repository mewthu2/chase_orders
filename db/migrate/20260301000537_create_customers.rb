class CreateCustomers < ActiveRecord::Migration[7.2]
  def change
    create_table :customers do |t|
      t.string :shopify_customer_id
      t.string :name
      t.string :email
      t.string :phone

      t.timestamps
    end
  end
end
