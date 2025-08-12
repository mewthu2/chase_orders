# app/jobs/update_products_cost_job.rb
class UpdateProductsCostJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info '=== Iniciando atualização de custo dos produtos ==='

    Rails.logger.info 'Atualizando custo no Tiny...'
    Tiny::Products.assert_cost

    Rails.logger.info 'Enviando custo para Shopify...'
    Shopify::Products.sync_shopify_data_on_product('cost')

    Rails.logger.info '=== Atualização de custo finalizada ==='
  rescue StandardError => e
    Rails.logger.error "Erro no UpdateProductsCostJob: #{e.message}"
  end
end
