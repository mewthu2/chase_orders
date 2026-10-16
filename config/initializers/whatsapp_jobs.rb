# Persistent outbox/event records are the source of truth; Sidekiq only transports IDs.
# Explicit adapter prevents development's :async queue from losing work on restart.
Rails.application.config.to_prepare do
  [Whatsapp::SendJob, Whatsapp::EventJob, Whatsapp::MediaJob, Whatsapp::ControlJob, Whatsapp::SyncJob].each do |job|
    job.queue_adapter = :sidekiq unless Rails.env.test?
  end
end
