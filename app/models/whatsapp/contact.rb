module Whatsapp
  class Contact < ApplicationRecord
    belongs_to :connection
    belongs_to :customer, optional: true
    has_many :aliases, class_name: 'Whatsapp::ContactAlias'
    def display_name = name.presence || phone.presence || 'Contato do WhatsApp'

    # Never infer a phone number from a LID. Only confirmed PN aliases are used.
    def self.resolve!(connection, key, name: nil)
      jids = [key['remoteJid'], key['remoteJidAlt']].compact.select { |j| Phone.individual_jid?(j) }.uniq
      raise ArgumentError, 'Conversa individual inválida' if jids.empty?
      matches = ContactAlias.where(connection: connection, jid: jids).pluck(:contact_id).uniq
      primary_id = ContactAlias.find_by(connection: connection, jid: jids.first)&.contact_id
      contact = connection.contacts.find_by(id: primary_id || matches.first) || connection.contacts.create!(provider_jid: jids.first)
      pn = jids.find { |j| j.end_with?('@s.whatsapp.net') }
      # O WhatsApp só manda LID + número juntos na mesma chave quando são a mesma pessoa:
      # aí as duas conversas que nasceram separadas (uma pelo LID, outra pelo número) viram uma.
      if pn && jids.any? { |j| j.end_with?('@lid') } && matches.size > 1
        keep_id = ContactAlias.find_by(connection: connection, jid: pn)&.contact_id || contact.id
        contact = connection.contacts.find(keep_id)
        connection.contacts.where(id: matches - [keep_id]).find_each { |other| contact.absorb!(other) }
        matches = [contact.id]
      end
      contact.name = name.to_s.truncate(100) if name.present?
      contact.phone = Phone.from_jid(pn) if pn
      contact.provider_jid = pn if pn && matches.size <= 1
      contact.save!
      jids.each do |jid|
        ContactAlias.find_or_create_by!(connection: connection, jid: jid) { |a| a.contact = contact }
      end
      contact
    end

    # Junta outro contato do mesmo número da empresa neste (apelidos, conversa, mensagens, leituras).
    def absorb!(other)
      return if other.id == id || other.connection_id != connection_id
      transaction do
        other.aliases.update_all(contact_id: id)
        mine = Conversation.find_by(connection_id: connection_id, contact_id: id)
        theirs = Conversation.find_by(connection_id: connection_id, contact_id: other.id)
        if theirs && mine
          mine.absorb!(theirs)
        elsif theirs
          theirs.update_columns(contact_id: id)
        end
        self.name = name.presence || other.name
        self.customer_id ||= other.customer_id
        self.phone ||= other.phone
        save!
        other.reload.destroy!
      end
    end
  end
end
