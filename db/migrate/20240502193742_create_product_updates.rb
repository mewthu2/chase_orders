class CreateProductUpdates < ActiveRecord::Migration[7.1]
  def change
    create_table :product_updates do |t|
      t.references :product, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.bigint :kinds
      t.string :field
      t.string :original_value
      t.string :modified_value
      t.string :json_return
      t.timestamps
    end
  end
end
