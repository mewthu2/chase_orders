class UploadSpreadsheetsDataJob < ApplicationJob
  queue_as :default

  def perform
    MakeSpreadsheetJob.perform_now('rj', 'product')
    MakeSpreadsheetJob.perform_now('rj', 'order')

    MakeSpreadsheetJob.perform_now('lagoa_seca', 'product')
    MakeSpreadsheetJob.perform_now('lagoa_seca', 'order')

    MakeSpreadsheetJob.perform_now('bh_shopping', 'product')
    MakeSpreadsheetJob.perform_now('bh_shopping', 'order')
  end
end
