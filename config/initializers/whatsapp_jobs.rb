# Persistent outbox/event records are the source of truth; Sidekiq only transports IDs.
# Só em produção: o REDIS_URL do .env de dev é o de produção, e um job enfileirado
# localmente seria executado pelo worker do Heroku (inclusive envio de mensagens).
# Em dev o :async pode perder jobs num restart; o Whatsapp::Recovery reenfileira.
Rails.application.config.to_prepare do
  [Whatsapp::SendJob, Whatsapp::EventJob, Whatsapp::MediaJob, Whatsapp::ControlJob, Whatsapp::SyncJob].each do |job|
    job.queue_adapter = :sidekiq if Rails.env.production?
  end
end
