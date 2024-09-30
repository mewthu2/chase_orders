class SyncOrdersSituationJob < ActiveJob::Base
  def perform
    sync_tiny_orders('lagoa_seca')
    sync_tiny_orders('bh_shopping')
  end
end
