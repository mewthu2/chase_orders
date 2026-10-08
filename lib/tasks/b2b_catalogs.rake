namespace :b2b_catalogs do
  desc 'Atualiza estoque e fotos dos catálogos B2B ativos (agendar no Heroku Scheduler a cada 1 hora)'
  task refresh: :environment do
    B2bCatalogRefreshJob.perform_now
  end
end
