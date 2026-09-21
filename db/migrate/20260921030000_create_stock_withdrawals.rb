class CreateStockWithdrawals < ActiveRecord::Migration[7.2]
  def change
    create_table :stock_withdrawals do |t|
      t.date :withdrawal_date, null: false
      t.string :reason, null: false, default: 'shrinkage' # motivo aceito pelo Shopify (histórico do inventário)
      t.text :notes
      t.integer :status, null: false, default: 0
      t.references :user, null: false, foreign_key: true
      t.datetime :completed_at

      t.timestamps
    end

    create_table :stock_withdrawal_items do |t|
      t.references :stock_withdrawal, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.references :location, null: false, foreign_key: true
      t.integer :quantity, null: false
      t.integer :status, null: false, default: 0
      t.integer :available_before
      t.text :error_message
      t.string :shopify_adjustment_id
      t.datetime :withdrawn_at

      t.timestamps
    end

    add_index :stock_withdrawal_items, [:stock_withdrawal_id, :product_id, :location_id],
              unique: true, name: 'idx_withdrawal_items_unique_product_location'
    add_index :stock_withdrawals, :status
  end
end
