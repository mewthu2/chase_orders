# Produto que não foi atualizado numa sincronização de estoque (Attempt kinds: :sync_correios_stock).
# stage: 'correios' (consulta do saldo falhou) ou 'shopify' (gravação no Shopify falhou).
class StockSyncFailure < ApplicationRecord
  STAGES = { 'correios' => 'Consulta no Correios', 'shopify' => 'Gravação no Shopify', 'lote' => 'Lote inteiro' }.freeze

  belongs_to :attempt
  belongs_to :product, optional: true

  def self.record!(attempt, product, stage, reason)
    create!(attempt_id: attempt.id, product_id: product&.id, sku: product&.sku, stage: stage, reason: reason.to_s.truncate(500), created_at: Time.current)
  rescue StandardError => e
    puts "Não foi possível registrar a falha de #{product&.sku}: #{e.message}"
  end
end
