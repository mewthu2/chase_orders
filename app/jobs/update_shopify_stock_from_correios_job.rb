class UpdateShopifyStockFromCorreiosJob < ActiveJob::Base
  BATCH_SIZE = 100

  def perform(attempt_id = nil)
    attempt = attempt_id ? Attempt.find(attempt_id) : create_new_attempt

    products = Product.where.not(sku: [nil, ''])
                      .where.not(shopify_inventory_item_id: [nil, ''])
                      .order(:id)

    total = products.count
    total_batches = (total.to_f / BATCH_SIZE).ceil

    stats = {
      total: total,
      total_batches: total_batches,
      processed_batches: 0,
      success: 0,
      failed: 0,
      errors: [],
      omitted_errors: 0,
      completed_batch_indexes: []
    }

    attempt.update!(
      status: :processing,
      message: "Sincronização iniciada em #{total_batches} lote(s) de #{BATCH_SIZE} produto(s).",
      params: stats.to_json
    )

    products.in_batches(of: BATCH_SIZE).each_with_index do |batch_relation, index|
      product_ids = batch_relation.pluck(:id)

      UpdateShopifyStockFromCorreiosBatchJob.perform_later(
        attempt.id,
        product_ids,
        index + 1,
        total_batches
      )
    end

    puts "Foram enfileirados #{total_batches} lote(s) para #{total} produto(s)."
  end

  private

  def create_new_attempt
    Attempt.create!(
      kinds: :sync_correios_stock,
      status: :processing,
      tracking: "auto_execution:#{Time.current.to_i}",
      message: 'Sincronização automática iniciada'
    )
  end
end