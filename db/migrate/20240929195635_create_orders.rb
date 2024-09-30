class CreateOrders < ActiveRecord::Migration[7.2]
  def change
    create_table :orders do |t|
      t.bigint :kinds
      t.integer :tiny_order_id
      t.timestamps
    end
  end
end
