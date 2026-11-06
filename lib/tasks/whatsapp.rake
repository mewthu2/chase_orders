namespace :whatsapp do
  desc 'Recupera eventos/envios pendentes e sincroniza os números (agendar a cada minuto)'
  task recover: :environment do
    Whatsapp::Recovery.call
  end

  desc 'Liga contatos só com LID ao número e junta conversas duplicadas (LID x número)'
  task merge_lid_contacts: :environment do
    merged = linked = 0
    Whatsapp::Connection.find_each do |connection|
      next unless connection.enabled?
      gateway = connection.gateway
      lids = Whatsapp::ContactAlias.where(connection: connection).where('jid LIKE ?', '%@lid')
      lids.find_each do |alias_row|
        next if Whatsapp::ContactAlias.where(contact_id: alias_row.contact_id).where('jid LIKE ?', '%@s.whatsapp.net').exists?
        key = gateway.chat(alias_row.jid)&.dig('lastMessage', 'key') || {}
        pn = [key['remoteJid'], key['remoteJidAlt']].find { |j| j.to_s.end_with?('@s.whatsapp.net') && Whatsapp::Phone.individual_jid?(j) }
        next unless pn
        connection.with_lock do
          duplicate = Whatsapp::ContactAlias.where(connection: connection, jid: pn).where.not(contact_id: alias_row.contact_id).exists?
          Whatsapp::Contact.resolve!(connection, { 'remoteJid' => alias_row.jid, 'remoteJidAlt' => pn })
          duplicate ? merged += 1 : linked += 1
        end
      rescue Whatsapp::Providers::Evolution::Error => e
        puts "#{alias_row.jid}: #{e.message}"
      end
    end
    puts "Conversas juntadas: #{merged} · contatos ligados ao número: #{linked}"
  end
end
