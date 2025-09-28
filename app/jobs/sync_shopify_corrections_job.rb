class SyncShopifyCorrectionsJob < ApplicationJob
  queue_as :default

  def perform(stock_correction_id, user_id = nil)
    Rails.logger.info "=== Starting SyncShopifyCorrectionsJob for stock_correction #{stock_correction_id} ==="

    stock_correction = StockCorrection.find(stock_correction_id)
    user = User.find(user_id) if user_id

    items_to_process = stock_correction.stock_correction_items.where(needs_correction: true, executed: false)

    Rails.logger.info "Found #{items_to_process.count} items to process"

    success_count = 0
    error_count = 0

    items_to_process.find_each do |item|
      Rails.logger.info "Processing item #{item.id} for product #{item.product.sku}"

      if item.execute_correction!(with_shopify_integration: true)
        success_count += 1
        Rails.logger.info "Successfully processed item #{item.id}"
      else
        error_count += 1
        Rails.logger.error "Failed to process item #{item.id}"
      end
    end

    stock_correction.complete_integration!

    Rails.logger.info '=== SyncShopifyCorrectionsJob completed ==='
    Rails.logger.info "Success: #{success_count}, Errors: #{error_count}"

    Rails.logger.info "Job completed for user #{user.name}" if user

  rescue StandardError => e
    Rails.logger.error "=== SyncShopifyCorrectionsJob failed ==="
    Rails.logger.error "Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    stock_correction.fail_integration!(e.message)
  end
end
