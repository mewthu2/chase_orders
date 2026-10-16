# Optional isolated Rails environment. Existing development/production settings are untouched.
require_relative 'development'

preview_url = ENV['HONEY_WHATSAPP_PREVIEW_DATABASE_URL'].to_s
unless preview_url.start_with?('mysql2://') && URI(preview_url).path.end_with?('_whatsapp_preview')
  raise 'Defina HONEY_WHATSAPP_PREVIEW_DATABASE_URL para um banco MySQL separado com nome terminado em _whatsapp_preview.'
end

Rails.application.configure do
  config.active_job.queue_adapter = :sidekiq
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = false
  config.active_storage.service = ENV.fetch('WHATSAPP_STORAGE_SERVICE', 'local').to_sym
  config.hosts << ENV['HONEY_WHATSAPP_PREVIEW_HOST'] if ENV['HONEY_WHATSAPP_PREVIEW_HOST'].present?
end
