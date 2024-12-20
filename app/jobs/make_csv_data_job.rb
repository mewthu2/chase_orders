class MakeCsvDataJob < ApplicationJob
  queue_as :default

  def perform
    log_job('SyncProductsSituationJob') { SyncProductsSituationJob.perform_now }
    log_job('Tiny::Products.assert_stock') { Tiny::Products.assert_stock }
    log_job('SyncOrdersSituationJob') { SyncOrdersSituationJob.perform_now }
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
