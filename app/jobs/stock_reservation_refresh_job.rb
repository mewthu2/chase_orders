class StockReservationRefreshJob < ActiveJob::Base
  queue_as :default

  def perform(account = nil)
    accounts = account.present? ? [account.to_s] : StockReservationRefresher::ACCOUNTS.keys
    accounts.each { |acc| StockReservationRefresher.call(acc) }
  end
end
