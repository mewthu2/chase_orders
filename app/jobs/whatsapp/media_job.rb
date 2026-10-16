module Whatsapp
  class MediaJob < ApplicationJob
    queue_as :whatsapp
    def perform(id)
      message = Message.find(id)
      retry_at = nil
      message.with_lock do
        return unless message.media_state == 'pending' && !message.media
        return if message.media_retry_at && message.media_retry_at > Time.current
        # Persist the budget in MySQL: recovery jobs and worker restarts cannot reset it.
        if message.media_attempts >= 4
          message.update!(media_state: 'unavailable')
          return
        end
        message.update!(media_attempts: message.media_attempts + 1, media_retry_at: nil)
        begin
          result = message.connection.gateway.media(message)
          encoded = result.fetch('base64')
          raise Media::Invalid, 'media_too_large' if encoded.bytesize > (Media::MAX_BYTES * 4 / 3 + 8)
          bytes = Base64.strict_decode64(encoded)
          Media.store!(message, StringIO.new(bytes), filename: result['fileName'] || 'arquivo')
        rescue Providers::Evolution::Unavailable
          if message.media_attempts >= 4
            message.update!(media_state: 'unavailable')
          else
            retry_at = (message.media_attempts**4 + 5).seconds.from_now
            message.update!(media_retry_at: retry_at)
          end
        rescue Media::Invalid, ArgumentError, KeyError, Providers::Evolution::Rejected, Providers::Evolution::NotConfigured
          message.update!(media_state: 'rejected')
        end
      end
      self.class.set(wait_until: retry_at).perform_later(id) if retry_at
    end
  end
end
