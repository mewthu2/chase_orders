module Whatsapp
  class SendJob < ApplicationJob
    queue_as :whatsapp
    def perform(id)
      message = Message.find(id)
      connection = message.connection
      connection.with_lock do
        message.reload
        return unless message.state == 'queued'
        unless connection.connected? && Connection.visible_to(message.user).where(id: connection.id).exists?
          message.update!(state: 'failed', error_code: 'number_unavailable_or_access_revoked')
          return
        end
        message.update!(state: 'sending', attempted_at: Time.current, error_code: nil)
      end
      # Durable sending marker survives a timeout, worker kill or transaction rollback.
      connection.with_lock do
        message.reload
        return unless message.state == 'sending'
        unless connection.connected? && Connection.visible_to(message.user).where(id: connection.id).exists?
          message.update!(state: 'failed', error_code: 'number_unavailable_or_access_revoked')
          return
        end
        response = connection.gateway.send_message(message)
        key = response['key'] || {}
        raise Providers::Evolution::Unavailable, 'missing_message_id' unless key['id'].present? && key['fromMe'] == true
        expected = message.conversation.contact.aliases.pluck(:jid) + [message.conversation.contact.provider_jid]
        raise Providers::Evolution::Unavailable, 'unexpected_recipient' unless expected.any? { |jid| [key['remoteJid'], key['remoteJidAlt']].compact.any? { |returned| Phone.equivalent_jid?(jid, returned) } }
        # Webhook processing holds the same connection lock; the HTTP response binds the
        # outbox record before an echo can create a duplicate.
        Ingest.new(connection).message!(response, outgoing: message)
      end
    rescue Providers::Evolution::NotConfigured
      Message.where(id: id, state: 'sending').update_all(state: 'failed', error_code: 'provider_not_configured')
    rescue StandardError => e
      # Even an HTTP error can occur after WhatsApp accepted a message. Never retry it.
      Message.where(id: id, state: 'sending').update_all(state: 'uncertain', error_code: 'send_result_unknown')
      Rails.logger.warn("whatsapp send #{id}: #{e.class.name}")
    end
  end
end
