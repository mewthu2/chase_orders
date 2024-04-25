class CreateProductUpdates < ActiveRecord::Migration[7.0]
  def change
    create_table :product_updates do |t|
      t.references :product, null: false, foreign_key: true, index: true
      t.string :modify_responsible
      t.string :field
      t.string :original_value
      t.string :modified_value
      t.timestamps
    end
  end
end
