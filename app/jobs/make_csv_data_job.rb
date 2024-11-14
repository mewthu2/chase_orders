class MakeCsvDataJob < ApplicationJob
  queue_as :default

  def perform
    SyncProductsSituationJob.perform_now
    SyncOrdersSituationJob.perform_now
    MakeSpreadsheetJob.perform_now('lagoa_seca', 'product')
    MakeSpreadsheetJob.perform_now('lagoa_seca', 'order')
    MakeSpreadsheetJob.perform_now('bh_shopping', 'product')
    MakeSpreadsheetJob.perform_now('bh_shopping', 'order')
  end
end
