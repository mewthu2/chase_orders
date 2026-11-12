class ScheduledStockSyncJob < ActiveJob::Base
  queue_as :stock_sync
  include SingleRun
  runs_one_at_a_time

  def perform
    config = StockSyncConfig.current_config

    return unless config.should_execute_now?

    # Rodada anterior ainda com lotes pendentes (a trava do job só cobre o enfileiramento dos lotes).
    if Attempt.where(kinds: :sync_correios_stock, status: :processing).where('created_at > ?', 6.hours.ago).exists?
      puts 'Sincronização anterior ainda em andamento; esta rodada foi ignorada.'
      return
    end

    puts 'Executando sincronização automática de estoque...'

    config.mark_as_executed!

    UpdateShopifyStockFromCorreiosJob.perform_now
  end
end
