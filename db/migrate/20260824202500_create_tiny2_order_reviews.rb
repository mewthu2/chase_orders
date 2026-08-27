class CreateTiny2OrderReviews < ActiveRecord::Migration[7.2]
  def change
    create_table :tiny2_order_reviews do |t|
      t.string :tiny_order_id, null: false
      t.integer :status, null: false

      t.timestamps
    end

    add_index :tiny2_order_reviews, :tiny_order_id, unique: true
  end
end
