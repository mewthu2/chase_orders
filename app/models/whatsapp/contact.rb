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
      # An existing conflict must not merge conversations or customer records.
      primary_id = ContactAlias.find_by(connection: connection, jid: jids.first)&.contact_id
      contact = connection.contacts.find_by(id: primary_id || matches.first) || connection.contacts.create!(provider_jid: jids.first)
      contact.name = name.to_s.truncate(100) if name.present?
      pn = jids.find { |j| j.end_with?('@s.whatsapp.net') }
      contact.phone = Phone.from_jid(pn) if pn
      contact.provider_jid = pn if pn && matches.size <= 1
      contact.save!
      jids.each do |jid|
        ContactAlias.find_or_create_by!(connection: connection, jid: jid) { |a| a.contact = contact }
      end
      contact
    end
  end
end
