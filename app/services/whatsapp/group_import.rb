module Whatsapp
  # Traz todos os grupos do número para o Honey (aparecem no filtro "Grupos", mesmo sem mensagem nova).
  # Enquanto a Evolution ignorava grupos ela não guardou nenhum: a lista vem direto do WhatsApp.
  class GroupImport
    def self.call(connection)
      groups = connection.gateway.groups
      created = 0
      connection.with_lock do
        groups.each do |g|
          next unless Phone.group_jid?(g['id'])
          contact = Contact.group!(connection, g['id'], name: g['subject'].presence)
          conversation = connection.conversations.find_or_initialize_by(contact: contact)
          next if conversation.persisted?
          # Sem mensagem ainda: entra pela data do assunto/criação, para não pular para o topo.
          at = [g['subjectTime'], g['creation']].map(&:to_i).find(&:positive?)
          conversation.last_message_at = Time.at(at).utc if at
          conversation.save!
          created += 1
        end
      end
      created
    end
  end
end
