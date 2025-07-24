# app/jobs/sync_shopify_inventory_job.rb
class SyncShopifyInventoryJob < ApplicationJob
  queue_as :default

  def perform
    puts '🔄 Iniciando sincronização de produtos com Shopify...'

    begin
      Shopify::Products.list_all_products('create_update_shopify_products')
      puts '✅ Sincronização finalizada com sucesso'
    rescue StandardError => e
      Rails.logger.error("❌ Erro ao sincronizar produtos da Shopify: #{e.message}")
      puts "❌ Falha ao sincronizar: #{e.message}"
    end
  end
end
