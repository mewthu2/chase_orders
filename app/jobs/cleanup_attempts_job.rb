# app/jobs/cleanup_attempts_job.rb
class CleanupAttemptsJob < ApplicationJob
  queue_as :default

  def perform
    cutoff_date = 1.week.ago

    [
      { kinds: :create_correios_order, status: :fail },
      { kinds: :send_xml,             status: :error },
      { kinds: :emission_invoice,     status: :error },
      { kinds: :get_tracking,         status: :error }
    ].each do |conditions|
      deleted_count = Attempt.where(conditions)
                             .where('created_at <= ?', cutoff_date)
                             .delete_all

      Rails.logger.info "CleanupAttemptsJob: Excluídos #{deleted_count} registros para #{conditions}"
    end
  end
end
