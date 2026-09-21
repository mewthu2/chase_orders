class AddReversalToStockWithdrawalItems < ActiveRecord::Migration[7.2]
  # Reversão de uma linha já retirada: devolve a quantidade ao estoque no Shopify (adição de estoque).
  def change
    add_column :stock_withdrawal_items, :reverted_at, :datetime
    add_column :stock_withdrawal_items, :reversal_adjustment_id, :string
    add_reference :stock_withdrawal_items, :reverted_by, foreign_key: { to_table: :users }, null: true
  end
end
