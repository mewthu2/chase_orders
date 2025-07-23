class ScheduledStockSyncJob < ActiveJob::Base
  def perform
    config = StockSyncConfig.current_config

    return unless config.should_execute_now?

    puts 'Executando sincronização automática de estoque...'

    config.mark_as_executed!

    UpdateShopifyStockFromCorreiosJob.perform_now
  end
end
