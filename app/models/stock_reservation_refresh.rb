# Estado da última atualização das reservas de cada conta (uma linha por conta).
class StockReservationRefresh < ApplicationRecord
  INTERVAL = 10.minutes
  STALE_RUN = 5.minutes
  STATUSES = %w[idle running success partial error].freeze

  enum :account, { b2b: 0, b2c: 1 }

  validates :status, inclusion: { in: STATUSES }

  def self.for(account)
    create_or_find_by!(account: account.to_s)
  end

  def next_refresh_at
    last_refreshed_at && last_refreshed_at + INTERVAL
  end

  # Um "running" mais velho que STALE_RUN é de uma execução que morreu no meio.
  def running_recently?
    status == 'running' && updated_at > STALE_RUN.ago
  end
end
