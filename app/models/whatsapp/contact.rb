module Whatsapp
  class Contact < ApplicationRecord
    belongs_to :connection
    belongs_to :customer, optional: true
    has_many :aliases, class_name: 'Whatsapp::ContactAlias'
    def display_name = name.presence || phone.presence || (group? ? 'Grupo do WhatsApp' : 'Contato do WhatsApp')
    def group? = Phone.group_jid?(provider_jid)
    scope :groups, -> { where('whatsapp_contacts.provider_jid LIKE ?', '%@g.us') }

    # Grupo: um contato só, pelo JID do grupo. O nome (assunto) vem da Evolution na primeira mensagem.
    def self.group!(connection, jid, name: nil)
      raise ArgumentError, 'Grupo inválido' unless Phone.group_jid?(jid)
      contact = ContactAlias.find_by(connection: connection, jid: jid)&.contact ||
                connection.contacts.find_by(provider_jid: jid) || connection.contacts.create!(provider_jid: jid)
      ContactAlias.find_or_create_by!(connection: connection, jid: jid) { |a| a.contact = contact }
      if name.present?
        contact.update!(name: name.to_s.truncate(100)) if contact.name != name.to_s.truncate(100)
      elsif contact.name.blank?
        contact.refresh_group_name!
      end
      contact
    end

    def refresh_group_name!
      subject = connection.gateway.group_subject(provider_jid)
      update!(name: subject.truncate(100)) if subject.present?
    rescue Providers::Evolution::Error
      nil
    end

    # Never infer a phone number from a LID. Only confirmed PN aliases are used.
    def self.resolve!(connection, key, name: nil)
      jids = [key['remoteJid'], key['remoteJidAlt']].compact.select { |j| Phone.individual_jid?(j) }.uniq
      raise ArgumentError, 'Conversa individual inválida' if jids.empty?
      # O número com e sem o nono dígito é o mesmo celular: procura pelas duas formas.
      lookup = jids.flat_map { |j| Phone.br_variants(j) }.uniq
      matches = ContactAlias.where(connection: connection, jid: lookup).pluck(:contact_id).uniq
      primary_id = ContactAlias.find_by(connection: connection, jid: jids.first)&.contact_id
      contact = connection.contacts.find_by(id: primary_id || matches.first) || connection.contacts.create!(provider_jid: jids.first)
      pn = jids.find { |j| j.end_with?('@s.whatsapp.net') }
      # Todos os JIDs procurados são da mesma pessoa (LID + número na mesma chave do WhatsApp, ou o
      # número com e sem o nono dígito): as conversas que nasceram separadas viram uma.
      if pn && matches.size > 1
        keep_id = ContactAlias.find_by(connection: connection, jid: pn)&.contact_id || contact.id
        # Fica o contato com nome (o que a cliente usa), não o criado ao digitar o número.
        named = connection.contacts.where(id: matches).where.not(name: [nil, '']).order(:id).first
        keep_id = named.id if named && connection.contacts.find(keep_id).name.blank?
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
