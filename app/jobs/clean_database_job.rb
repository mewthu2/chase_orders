class CleanDatabaseJob < ActiveJob::Base
  def perform
    Attempt.where(status: '1').limit(10000).destroy_all
  end
end
