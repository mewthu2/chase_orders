module Whatsapp
  class ControlJob < ApplicationJob
    queue_as :whatsapp
    def perform(id, version)
      connection = Connection.find(id)
      connection.with_lock do
        return unless connection.control_version == version && connection.control_action
        gateway = connection.gateway
        if connection.control_action == 'disconnect'
          gateway.disconnect
          connection.update!(state: 'disconnected', qr_data: nil, qr_expires_at: nil, provider_updated_at: Time.current)
        else
          gateway.ensure_instance
          result = connection.control_action == 'reconnect' ? gateway.reconnect : gateway.connect
          Ingest.new(connection).qr!(result)
          Ingest.new(connection).connection!(gateway.state)
        end
        connection.update!(control_action: nil, error_code: nil)
      end
      SyncJob.perform_later(id) if connection.connected?
    rescue Providers::Evolution::Error => e
      Connection.where(id: id, control_version: version).update_all(state: 'unavailable', error_code: e.message, control_action: nil)
    end
  end
end
