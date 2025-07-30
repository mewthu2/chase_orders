class CreateStockCorrections < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_corrections do |t|
      t.date :correction_date, null: false
      t.string :reason, null: false
      t.string :location, null: false
      t.string :status, default: 'pending'
      t.text :notes
      t.datetime :executed_at
      t.references :user, null: true, foreign_key: true
      
      t.timestamps
    end
    
    add_index :stock_corrections, [:location, :status]
    add_index :stock_corrections, :correction_date
  end
end
