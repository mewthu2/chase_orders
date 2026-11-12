# app/jobs/cleanup_attempts_job.rb
class CleanupAttemptsJob < ApplicationJob
  include SingleRun
  runs_one_at_a_time

  queue_as :default

  def perform
    cutoff_date = 1.week.ago

    deleted_count =
      Attempt.where.not(status: :success)
             .where('created_at <= ?', cutoff_date)
             .delete_all

    Rails.logger.info(
      "CleanupAttemptsJob: Excluídos #{deleted_count} registros com status diferente de success "\
      "criados até #{cutoff_date}"
    )
  end
end
