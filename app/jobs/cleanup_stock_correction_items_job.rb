# app/jobs/cleanup_stock_correction_items_job.rb
class CleanupStockCorrectionItemsJob < ApplicationJob
  queue_as :default

  def perform
    cutoff_date = 1.week.ago

    StockCorrection.where(status: 'executed')
                   .where('updated_at < ?', cutoff_date)
                   .find_each do |correction|
      items_to_delete = correction.stock_correction_items.where(needs_correction: false)

      if items_to_delete.exists?
        Rails.logger.info "🧹 Removendo #{items_to_delete.count} itens sem correção do StockCorrection ##{correction.id}"
        items_to_delete.destroy_all
      end
    end

    Rails.logger.info "✅ CleanupStockCorrectionItemsJob concluído com sucesso"
  end
end
