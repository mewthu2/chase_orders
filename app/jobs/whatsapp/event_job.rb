module Whatsapp
  class EventJob < ApplicationJob
    queue_as :whatsapp
    retry_on ActiveRecord::Deadlocked, wait: 2.seconds, attempts: 3
    def perform(id)
      event = Event.find(id)
      event.connection.with_lock do
        event.reload
        return if event.processed_at || event.attempts >= 5
        event.increment!(:attempts)
        ingest = Ingest.new(event.connection)
        data = JSON.parse(event.payload)
        case event.kind
        when 'qrcode.updated' then ingest.qr!(data, occurred_at: event.occurred_at)
        when 'connection.update' then ingest.connection!(data, occurred_at: event.occurred_at)
        when 'messages.upsert', 'messages.set', 'send.message'
          (data.is_a?(Array) ? data : [data]).each { |item| ingest.message!(item, historical: event.kind == 'messages.set') }
        when 'messages.update'
          (data.is_a?(Array) ? data : [data]).each { |item| ingest.receipt!(item) }
        end
        event.update!(processed_at: Time.current, error_code: nil)
      end
      event.connection.messages.where(media_state: 'pending').limit(100).pluck(:id).each { |mid| MediaJob.perform_later(mid) }
    rescue ActiveRecord::RecordNotFound
      nil
    rescue StandardError => e
      Event.where(id: id).update_all(error_code: e.class.name, attempts: event&.attempts.to_i.clamp(1, 5))
      raise
    end
  end
end
