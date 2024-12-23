class MakeCsvDataJob < ApplicationJob
  queue_as :default

  def perform
    log_job('SyncProductsSituationJob') { log_motor_activity('SyncProductsSituationJob') { SyncProductsSituationJob.perform_now } }
    log_job('Tiny::Products.assert_stock') { log_motor_activity('Tiny::Products.assert_stock') { Tiny::Products.assert_stock } }
    log_job('SyncOrdersSituationJob') { log_motor_activity('SyncOrdersSituationJob') { SyncOrdersSituationJob.perform_now } }
  end

  private

  def log_job(job_name)
    Rails.logger.info "=== Início do #{job_name} ==="
    start_time = Time.now

    yield

    duration = Time.now - start_time
    Rails.logger.info "=== Fim do #{job_name} (Tempo de execução: #{duration.round(2)} segundos) ==="
  end

  def log_motor_activity(job_name)
    motor = Motor.last

    Rails.logger.info "=== Início do motor #{job_name} ==="
    Rails.logger.info "Start Time: #{motor.start_time}"
    Rails.logger.info "End Time: #{motor.end_time.nil? ? 'Ainda em progresso' : motor.end_time}"
    Rails.logger.info "Running Time: #{motor.running_time} segundos"
    Rails.logger.info "Link: #{motor.link.nil? ? 'Sem link' : motor.link}"

    if motor.end_time.nil?
      Rails.logger.info "Motor #{job_name} ainda está em execução..."
    else
      duration = motor.running_time
      Rails.logger.info "=== Fim do motor #{job_name} (Tempo de execução: #{duration.round(2)} segundos) ==="
    end

    yield
  end
end
