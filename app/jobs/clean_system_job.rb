class CleanSystemJob < ActiveJob::Base
  def perform
    clean_create_order_attempts
  end

  def clean_create_order_attempts
    ten_days_ago = 15.days.ago
    Attempt.where('created_at >= ? AND created_at < ?', ten_days_ago.beginning_of_day, ten_days_ago.end_of_day).destroy_all
  end
end
