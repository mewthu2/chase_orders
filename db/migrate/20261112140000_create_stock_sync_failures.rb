# Cada produto que falhou numa sincronização de estoque Correios → Shopify (uma linha por SKU),
# para a tela da execução listar todos e não só os 50 primeiros erros guardados no params.
class CreateStockSyncFailures < ActiveRecord::Migration[8.0]
  def change
    create_table :stock_sync_failures, if_not_exists: true do |t|
      t.bigint :attempt_id, null: false
      t.bigint :product_id
      t.string :sku
      t.string :stage
      t.string :reason, limit: 500
      t.datetime :created_at, null: false
    end
    add_index :stock_sync_failures, :attempt_id, if_not_exists: true
  end
end
