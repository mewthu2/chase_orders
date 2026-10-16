namespace :whatsapp do
  desc 'Recupera eventos/envios pendentes e sincroniza os números (agendar a cada minuto)'
  task recover: :environment do
    Whatsapp::Recovery.call
  end
end
