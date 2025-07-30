class CreateStockCorrectionItems < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_correction_items do |t|
      t.references :stock_correction, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.boolean :checked, default: false
      t.boolean :needs_correction, default: false
      t.integer :current_stock
      t.integer :corrected_stock
      t.string :correction_reason
      t.boolean :executed, default: false
      t.datetime :executed_at
      
      t.timestamps
    end
    
    add_index :stock_correction_items, [:stock_correction_id, :product_id], unique: true
    add_index :stock_correction_items, :needs_correction
  end
end
