module Whatsapp
  class Ingest
    STATUS_RANKS = { 'SERVER_ACK' => 1, 'DELIVERY_ACK' => 2, 'READ' => 3, 'PLAYED' => 3,
      '2' => 1, '3' => 2, '4' => 3, '5' => 3 }.freeze
    # Figurinha é uma imagem WEBP; vídeo de bolinha (ptv) é um vídeo comum.
    MEDIA_KINDS = { 'imageMessage' => 'image', 'stickerMessage' => 'image', 'documentMessage' => 'document',
      'audioMessage' => 'audio', 'videoMessage' => 'video', 'ptvMessage' => 'video' }.freeze
    def initialize(connection) = @connection = connection

    def message!(data, historical: false, outgoing: nil)
      return unless data.is_a?(Hash)
      key = data['key'] || {}
      return unless Phone.chat_jid?(key['remoteJid']) && key['id'].to_s.match?(/\A[\w.:-]{1,191}\z/)
      # Edição/exclusão chegam como mensagem de protocolo: não viram balão "não suportado".
      return if data['message'].is_a?(Hash) && (data['message'].key?('protocolMessage') || data['message'].key?('editedMessage'))
      # Called under the connection lock by webhook, sync, or send workers.
      existing = @connection.messages.find_by(provider_id: key['id'])
      if existing
        # A sincronização relê a chave completa (LID + número): aproveita para juntar contatos.
        Contact.resolve!(@connection, key) if !outgoing && lid_pair?(key)
        receipt!(data.merge('keyId' => key['id']))
        return existing
      end
      group = Phone.group_jid?(key['remoteJid'])
      key = with_lid(key) unless outgoing || group
      if outgoing
        conversation = outgoing.conversation
        contact = conversation.contact
        [key['remoteJid'], key['remoteJidAlt']].compact.select { |jid| Phone.individual_jid?(jid) }.each do |jid|
          ContactAlias.find_or_create_by!(connection: @connection, jid: jid) { |a| a.contact = contact }
        end
      elsif group
        contact = Contact.group!(@connection, key['remoteJid'])
        conversation = @connection.conversations.find_or_create_by!(contact: contact)
      else
        contact = Contact.resolve!(@connection, key, name: key['fromMe'] ? nil : data['pushName'])
        conversation = @connection.conversations.find_or_create_by!(contact: contact)
      end
      raw = data['message'].is_a?(Hash) ? data['message'] : {}
      %w[ephemeralMessage viewOnceMessage viewOnceMessageV2 documentWithCaptionMessage].each do |wrapper|
        raw = raw.dig(wrapper, 'message') || raw
      end
      kind, media = MEDIA_KINDS.filter_map { |field, k| [k, raw[field]] if raw[field].is_a?(Hash) }.first
      text = raw['conversation'] || raw.dig('extendedTextMessage', 'text') || media&.dig('caption')
      kind ||= text.present? ? 'text' : 'unsupported'
      timestamp = data['messageTimestamp'].to_i
      time = timestamp.positive? && timestamp <= 5.minutes.from_now.to_i ? Time.at(timestamp).utc : Time.current
      message = outgoing || conversation.messages.new(connection: @connection)
      message.assign_attributes(provider_id: key['id'], provider_key: key.slice('id', 'remoteJid', 'remoteJidAlt', 'fromMe', 'participant'),
        direction: key['fromMe'] ? 'outgoing' : 'incoming', state: key['fromMe'] ? 'sent' : 'received',
        receipt_rank: key['fromMe'] ? 1 : 0, sent_at: time, historical: historical)
      unless outgoing
        message.assign_attributes(kind: kind, body: text.to_s.truncate(10_000), media_state: media ? 'pending' : nil)
      end
      message.sender_name = group_sender(key, data) if group && !key['fromMe']
      message.save!
      receipt!(data.merge('keyId' => key['id']))
      message.apply_receipt!(@connection.receipts.find_by(provider_id: key['id'])&.rank.to_i)
      if !conversation.last_message_at || time >= conversation.last_message_at
        conversation.update!(last_message_at: time, last_message_preview: message.preview.truncate(180))
      end
      # Grupo não entra na fila de atendimento nem passa pelo agente: só fica registrado (e conta como não lida).
      unless historical || group
        if message.direction == 'incoming'
          conversation.customer_wrote!
          AgentJob.schedule(conversation, message)
        elsif !outgoing
          # Escrita direto no celular da empresa: a equipe assumiu, o agente pausa nesta conversa.
          conversation.team_replied!(pause_agent: true)
        end
      end
      # Provider stores the encrypted media; fetch by its message key, never by arbitrary webhook URLs.
      if media && !outgoing
        size = media['fileLength'].is_a?(Hash) ? media['fileLength']['low'].to_i : media['fileLength'].to_i
        message.update!(media_state: 'rejected') if size > Media::MAX_BYTES
      end
      message
    end

    # A Evolution 2.3.7 troca o LID pelo número no webhook e perde o LID (remoteJid == remoteJidAlt).
    # Ela guarda a chave original: busca uma vez para ligar o LID ao número e não abrir outra conversa.
    def with_lid(key)
      return key if key['addressingMode'] != 'lid' || lid_pair?(key)
      pn = [key['remoteJid'], key['remoteJidAlt']].find { |j| j.to_s.end_with?('@s.whatsapp.net') }
      return key unless pn
      known = ContactAlias.find_by(connection: @connection, jid: pn)
      return key if known && ContactAlias.where(contact_id: known.contact_id).where('jid LIKE ?', '%@lid').exists?
      stored = @connection.gateway.find_message(key['id']).first&.dig('key') || {}
      lid = [stored['remoteJid'], stored['remoteJidAlt']].find { |j| j.to_s.end_with?('@lid') && Phone.individual_jid?(j) }
      lid ? key.merge('remoteJid' => lid, 'remoteJidAlt' => pn) : key
    rescue Providers::Evolution::Error
      key
    end

    # Quem escreveu no grupo: nome do WhatsApp; sem nome, o telefone (o LID não é telefone).
    def group_sender(key, data)
      name = data['pushName'].to_s.strip
      return name.truncate(120) if name.present?
      jid = [key['participantAlt'], key['participant']].find { |j| j.to_s.end_with?('@s.whatsapp.net') }
      Phone.from_jid(jid) || 'Participante'
    end

    def lid_pair?(key)
      jids = [key['remoteJid'], key['remoteJidAlt']].select { |j| Phone.individual_jid?(j) }
      jids.any? { |j| j.end_with?('@lid') } && jids.any? { |j| j.end_with?('@s.whatsapp.net') }
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
