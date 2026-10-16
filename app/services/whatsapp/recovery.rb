module Whatsapp
  class Recovery
    def self.call
      # Run once/minute via the dedicated worker's scheduler. Durable rows survive Redis loss.
      Event.where(processed_at: nil).where('attempts < 5').find_each { |e| EventJob.perform_later(e.id) }
      Message.where(state: 'queued').find_each { |m| SendJob.perform_later(m.id) }
      Message.where(state: 'sending').where('attempted_at < ?', 2.minutes.ago).update_all(state: 'uncertain', error_code: 'worker_interrupted')
      Message.where(media_state: 'pending').where('media_retry_at IS NULL OR media_retry_at <= ?', Time.current)
        .find_each { |m| MediaJob.perform_later(m.id) }
      Connection.find_each do |connection|
        if connection.control_action
          ControlJob.perform_later(connection.id, connection.control_version)
        elsif connection.enabled? && (!connection.sync_requested_at || connection.sync_requested_at < 1.minute.ago)
          connection.update!(sync_requested_at: Time.current)
          SyncJob.perform_later(connection.id)
        end
      end
    end
  end
end
