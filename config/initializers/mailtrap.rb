# E-mails de produção e desenvolvimento pelo add-on Mailtrap da Heroku (Email Sandbox). O add-on
# só expõe MAILTRAP_API_TOKEN; as credenciais SMTP vêm da API do Mailtrap (primeira inbox).
# Em dev, sem o token no .env, fica o SMTP local de config/environments/development.rb.
# Atenção: é um sandbox — os e-mails ficam na inbox do Mailtrap e não chegam aos usuários.
# Com MAILTRAP_SENDING_TOKEN definido, usa o Email Sending (envio real) no lugar do sandbox.
# Com SMTP_ADDRESS definido (e SMTP_USERNAME/SMTP_PASSWORD), usa esse SMTP no lugar dos dois.
require 'rest-client'
require 'json'

module MailtrapSandbox
  INBOXES_URL = 'https://mailtrap.io/api/v1/inboxes.json'.freeze

  def self.smtp_settings(token)
    # timeout curto: roda no boot de cada dyno e o Heroku derruba quem passa de 60s para subir
    response = RestClient::Request.execute(method: :get, url: INBOXES_URL, headers: { Authorization: "Bearer #{token}" }, timeout: 5)
    inbox = JSON.parse(response.body).first
    raise 'nenhuma inbox encontrada no Mailtrap' unless inbox

    {
      user_name: inbox['username'],
      password: inbox['password'],
      address: inbox['domain'],
      domain: inbox['domain'],
      port: inbox['smtp_ports'].first,
      authentication: :plain
    }
  end
end

if Rails.env.production? || Rails.env.development?
  ActiveSupport.on_load(:action_mailer) do
    self.default_url_options = { host: ENV.fetch('APP_HOST', 'localhost'), protocol: 'https' } if Rails.env.production?

    token = ENV['MAILTRAP_API_TOKEN']
    sending_token = ENV['MAILTRAP_SENDING_TOKEN']
    if ENV['SMTP_ADDRESS'].present?
      # SMTP de qualquer provedor (ex.: Gmail com senha de app, sem domínio próprio). Tem prioridade
      # sobre o Mailtrap; o remetente sai do próprio usuário SMTP quando MAILER_FROM não está definido.
      self.delivery_method = :smtp
      self.smtp_settings = {
        address: ENV['SMTP_ADDRESS'],
        port: ENV.fetch('SMTP_PORT', 587).to_i,
        user_name: ENV['SMTP_USERNAME'],
        password: ENV['SMTP_PASSWORD'],
        domain: ENV['SMTP_USERNAME'].to_s.split('@').last.presence || 'localhost',
        authentication: :plain,
        enable_starttls_auto: true
      }
    elsif sending_token.present?
      # Email Sending (envio real): exige o domínio do MAILER_FROM verificado no Mailtrap.
      self.delivery_method = :smtp
      self.smtp_settings = {
        user_name: 'api',
        password: sending_token,
        address: 'live.smtp.mailtrap.io',
        domain: ENV['MAILER_FROM'].to_s.split('@').last.presence || 'localhost',
        port: 587,
        authentication: :plain,
        enable_starttls_auto: true
      }
    elsif token.present?
      begin
        self.delivery_method = :smtp
        self.smtp_settings = MailtrapSandbox.smtp_settings(token)
      rescue StandardError => e
        Rails.logger.error("[Mailtrap] não foi possível configurar o SMTP: #{e.class}: #{e.message}")
      end
    end
  end
end
