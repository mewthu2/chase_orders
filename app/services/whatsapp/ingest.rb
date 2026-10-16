module Whatsapp
  class Ingest
    STATUS_RANKS = { 'SERVER_ACK' => 1, 'DELIVERY_ACK' => 2, 'READ' => 3, 'PLAYED' => 3,
      '2' => 1, '3' => 2, '4' => 3, '5' => 3 }.freeze
    def initialize(connection) = @connection = connection

    def message!(data, historical: false, outgoing: nil)
      return unless data.is_a?(Hash)
      key = data['key'] || {}
      return unless Phone.individual_jid?(key['remoteJid']) && key['id'].to_s.match?(/\A[\w.:-]{1,191}\z/)
      # Called under the connection lock by webhook, sync, or send workers.
      existing = @connection.messages.find_by(provider_id: key['id'])
      if existing
        receipt!(data.merge('keyId' => key['id']))
        return existing
      end
      if outgoing
        conversation = outgoing.conversation
        contact = conversation.contact
        [key['remoteJid'], key['remoteJidAlt']].compact.select { |jid| Phone.individual_jid?(jid) }.each do |jid|
          ContactAlias.find_or_create_by!(connection: @connection, jid: jid) { |a| a.contact = contact }
        end
      else
        contact = Contact.resolve!(@connection, key, name: key['fromMe'] ? nil : data['pushName'])
        conversation = @connection.conversations.find_or_create_by!(contact: contact)
      end
      raw = data['message'].is_a?(Hash) ? data['message'] : {}
      %w[ephemeralMessage viewOnceMessage viewOnceMessageV2 documentWithCaptionMessage].each do |wrapper|
        raw = raw.dig(wrapper, 'message') || raw
      end
      kind, media = %w[image document audio].filter_map { |k| [k, raw["#{k}Message"]] if raw["#{k}Message"].is_a?(Hash) }.first
      text = raw['conversation'] || raw.dig('extendedTextMessage', 'text') || media&.dig('caption')
      kind ||= text.present? ? 'text' : 'unsupported'
      timestamp = data['messageTimestamp'].to_i
      time = timestamp.positive? && timestamp <= 5.minutes.from_now.to_i ? Time.at(timestamp).utc : Time.current
      message = outgoing || conversation.messages.new(connection: @connection)
      message.assign_attributes(provider_id: key['id'], provider_key: key.slice('id', 'remoteJid', 'remoteJidAlt', 'fromMe'),
        direction: key['fromMe'] ? 'outgoing' : 'incoming', state: key['fromMe'] ? 'sent' : 'received',
        receipt_rank: key['fromMe'] ? 1 : 0, sent_at: time, historical: historical)
      unless outgoing
        message.assign_attributes(kind: kind, body: text.to_s.truncate(10_000), media_state: media ? 'pending' : nil)
      end
      message.save!
      receipt!(data.merge('keyId' => key['id']))
      message.apply_receipt!(@connection.receipts.find_by(provider_id: key['id'])&.rank.to_i)
      if !conversation.last_message_at || time >= conversation.last_message_at
        conversation.update!(last_message_at: time, last_message_preview: message.preview.truncate(180))
      end
      conversation.update!(state: 'open') if !historical && message.direction == 'incoming'
      # Provider stores the encrypted media; fetch by its message key, never by arbitrary webhook URLs.
      if media && !outgoing
        size = media['fileLength'].is_a?(Hash) ? media['fileLength']['low'].to_i : media['fileLength'].to_i
        message.update!(media_state: 'rejected') if size > Media::MAX_BYTES
      end
      message
    end

    def receipt!(data)
      id = data['keyId'] || data.dig('key', 'id')
      rank = STATUS_RANKS[data['status'].to_s]
      return unless id.present? && rank
      receipt = @connection.receipts.find_or_initialize_by(provider_id: id)
      receipt.rank = [receipt.rank || 0, rank].max
      receipt.save!
      @connection.messages.find_by(provider_id: id)&.apply_receipt!(receipt.rank)
    end

    def connection!(data, occurred_at: Time.current)
      return if @connection.last_event_at && occurred_at < @connection.last_event_at
      state = { 'open' => 'connected', 'connecting' => 'connecting', 'close' => 'disconnected' }[data['state']]
      return unless state
      state = 'disconnected' unless @connection.enabled?
      phone = Phone.from_jid(data['wuid'])
      attrs = { state: state, last_event_at: occurred_at, provider_updated_at: Time.current, error_code: nil }
      attrs[:phone] = phone if phone && state == 'connected'
      attrs.merge!(qr_data: nil, qr_expires_at: nil) if %w[connected disconnected].include?(state)
      @connection.update!(attrs)
    end

    def qr!(data, occurred_at: Time.current)
      return unless @connection.enabled? && @connection.state != 'connected'
      return if @connection.last_event_at && occurred_at < @connection.last_event_at
      raw = data.dig('qrcode', 'base64') || data['base64']
      return unless raw.to_s.match?(/\Adata:image\/png;base64,[A-Za-z0-9+\/=]+\z/) && raw.bytesize < 150_000
      return if @connection.qr_data == raw # A cached QR must never have its lifetime extended.
      # Baileys rotates QR; conservatively hide this value after 30s or earlier on connection.
      @connection.update!(qr_data: raw, qr_expires_at: occurred_at + 30.seconds, state: 'qr', last_event_at: occurred_at)
    end
  end
end
