namespace :stock_reservations do
  desc 'Atualiza as reservas de estoque da fila do Tiny (agendar no Heroku Scheduler a cada 10 min)'
  task refresh: :environment do
    StockReservationRefreshJob.perform_now
  end
end
