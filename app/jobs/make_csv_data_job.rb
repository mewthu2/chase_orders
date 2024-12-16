class MakeCsvDataJob < ApplicationJob
  queue_as :default

  def perform
    log_job('SyncProductsSituationJob') { SyncProductsSituationJob.perform_now }
    log_job('Tiny::Products.assert_stock') { Tiny::Products.assert_stock }
    log_job('SyncOrdersSituationJob') { SyncOrdersSituationJob.perform_now }
    log_job('MakeSpreadsheetJob - lagoa_seca, product') { MakeSpreadsheetJob.perform_now('lagoa_seca', 'product') }
    log_job('MakeSpreadsheetJob - lagoa_seca, order') { MakeSpreadsheetJob.perform_now('lagoa_seca', 'order') }
    log_job('MakeSpreadsheetJob - bh_shopping, product') { MakeSpreadsheetJob.perform_now('bh_shopping', 'product') }
    log_job('MakeSpreadsheetJob - bh_shopping, order') { MakeSpreadsheetJob.perform_now('bh_shopping', 'order') }
    log_job('MakeSpreadsheetJob - rj, product') { MakeSpreadsheetJob.perform_now('rj', 'product') }
    log_job('MakeSpreadsheetJob - rj, order') { MakeSpreadsheetJob.perform_now('rj', 'order') }
  end

  private

  def log_job(job_name)
    Rails.logger.info "=== Início do #{job_name} ==="
    start_time = Time.now

    yield

    duration = Time.now - start_time
    Rails.logger.info "=== Fim do #{job_name} (Tempo de execução: #{duration.round(2)} segundos) ==="
  end
end
