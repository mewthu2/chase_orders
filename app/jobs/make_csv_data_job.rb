class MakeCsvDataJob < ApplicationJob
  queue_as :default

  def perform
    motor = find_or_create_motor('Atualização de produtos')
    log_job('SyncProductsSituationJob') { run_job_and_update_motor(motor) { SyncProductsSituationJob.perform_now } }

    motor = find_or_create_motor('Atualização de estoque')
    log_job('Tiny::Products.assert_stock') { run_job_and_update_motor(motor) { Tiny::Products.assert_stock } }

    motor = find_or_create_motor('Atualização dos pedidos')
    log_job('SyncOrdersSituationJob') { run_job_and_update_motor(motor) { SyncOrdersSituationJob.perform_now } }
  end

  private

  def log_job(job_name)
    Rails.logger.info "=== Início do #{job_name} ==="
    start_time = Time.now

    yield

    duration = Time.now - start_time
    Rails.logger.info "=== Fim do #{job_name} (Tempo de execução: #{duration.round(2)} segundos) ==="
  end

  def find_or_create_motor(job_name)
    Motor.find_or_create_by(job_name:) do |motor|
      motor.start_time = Time.now
      motor.running_time = 0
    end
  end

  def run_job_and_update_motor(motor)
    yield
    motor.update(end_time: Time.now, running_time: (motor.end_time - motor.start_time).to_i)
  end
end
