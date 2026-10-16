module Whatsapp
  class SyncJob < ApplicationJob
    queue_as :whatsapp
    retry_on Providers::Evolution::Unavailable, wait: :polynomially_longer, attempts: 4
    def perform(id)
      connection = Connection.find(id)
      return unless connection.enabled?
      gateway = connection.gateway
      connection.with_lock { Ingest.new(connection).connection!(gateway.state) }
      return unless connection.connected?
      from = (connection.last_synced_at || 7.days.ago) - 5.minutes
      to = Time.current
      page = 1
      loop do
        result = gateway.history(from: from, to: to, page: page)
        connection.with_lock do
          return unless connection.enabled?
          (result['records'] || []).each { |data| Ingest.new(connection).message!(data, historical: connection.last_synced_at.nil?) }
        end
        break if page >= result['pages'].to_i
        # Keep the watermark unchanged if backfill exceeds this bounded job.
        if page >= 100
          connection.update!(error_code: 'sync_limit_reached')
          return
        end
        page += 1
      end
      connection.update!(last_synced_at: to, error_code: nil)
      connection.messages.where(media_state: 'pending').limit(100).pluck(:id).each { |mid| MediaJob.perform_later(mid) }
    rescue Providers::Evolution::Error => e
      Connection.where(id: id).update_all(state: 'unavailable', error_code: e.message)
      raise if e.is_a?(Providers::Evolution::Unavailable)
    end
  end
end
