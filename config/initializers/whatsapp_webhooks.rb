require Rails.root.join('lib/whatsapp_webhook_body_limit')
# Rack::MethodOverride parses multipart POSTs too, so bound the body before it runs.
Rails.application.config.middleware.insert_before Rack::MethodOverride, WhatsappWebhookBodyLimit
