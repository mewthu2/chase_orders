namespace :tickets do
  desc 'Envia o e-mail de prazo vencido dos chamados (agendar no Heroku Scheduler a cada 10 min)'
  task notify_overdue: :environment do
    TicketOverdueJob.perform_now
  end
end
