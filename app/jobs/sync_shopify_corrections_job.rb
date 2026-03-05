class SyncShopifyCorrectionsJob < ApplicationJob
  queue_as :default

  def perform(stock_correction_id, user_id, items_to_process)
    Rails.logger.info "=== Starting SyncShopifyCorrectionsJob for stock_correction #{stock_correction_id} ==="
    stock_correction = StockCorrection.find(stock_correction_id)
    user = User.find(user_id)

    Rails.logger.info "Found #{items_to_process.count} items to process (shopify_sync_status: error)"

    success_count = 0
    error_count = 0
    skipped_count = 0

    items_to_process.find_each(batch_size: 1000) do |item|
      Rails.logger.info "Processing item #{item.id} for product #{item.product.sku}"

      if item.executed?
        result = item.sync_with_shopify!
        if result
          success_count += 1
          Rails.logger.info "✅ Successfully synced item #{item.id}"
        else
          error_count += 1
          Rails.logger.error "❌ Failed to sync item #{item.id}"
        end
      else
        result = item.execute_correction!(with_shopify_integration: true)
        if result
          success_count += 1
          Rails.logger.info "✅ Successfully processed item #{item.id}"
        else
          error_count += 1
          Rails.logger.error "❌ Failed to process item #{item.id}"
        end
      end
    end

    if error_count.zero?
      stock_correction.complete_integration!
    else
      stock_correction.update!(integration_status: 'error')
    end

    Rails.logger.info '=== SyncShopifyCorrectionsJob completed ==='
    Rails.logger.info "Success: #{success_count}, Errors: #{error_count}, Skipped: #{skipped_count}"
    Rails.logger.info "Job completed for user #{user.name}"
  end
end