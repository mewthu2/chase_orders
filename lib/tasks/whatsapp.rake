namespace :whatsapp do
  desc 'Recupera eventos/envios pendentes e sincroniza os números (agendar a cada minuto)'
  task recover: :environment do
    Whatsapp::Recovery.call
  end

  desc 'Traz para o Honey todos os grupos de cada número conectado'
  task import_groups: :environment do
    Whatsapp::Connection.find_each do |connection|
      next unless connection.enabled? && connection.connected?
      puts "#{connection.name}: #{Whatsapp::GroupImport.call(connection)} grupo(s) novo(s)"
    rescue Whatsapp::Providers::Evolution::Error => e
      puts "#{connection.name}: #{e.message}"
    end
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

  desc 'Junta contatos do mesmo celular gravados com e sem o nono dígito (DRY_RUN=1 só mostra)'
  task merge_ninth_digit_contacts: :environment do
    canonical = ->(jid) { n = jid.split('@').first; n.length == 13 && n.start_with?('55') && n[4] == '9' ? n[0, 4] + n[5..] : n }
    merged = 0
    Whatsapp::Connection.find_each do |connection|
      rows = Whatsapp::ContactAlias.where(connection: connection).where('jid LIKE ?', '%@s.whatsapp.net').pluck(:jid, :contact_id)
      rows.group_by { |jid, _| canonical.(jid) }.each_value do |group|
        next if group.map(&:last).uniq.size < 2
        names = Whatsapp::Contact.where(id: group.map(&:last)).map { |c| "#{c.id}:#{c.display_name}" }
        puts "#{connection.name}: #{group.map(&:first).uniq.join(' + ')} -> #{names.join(' | ')}"
        next if ENV['DRY_RUN']
        connection.with_lock { Whatsapp::Contact.resolve!(connection, { 'remoteJid' => group.first.first }) }
        merged += 1
      end
    end
    puts "Contatos juntados: #{merged}"
  end
end
