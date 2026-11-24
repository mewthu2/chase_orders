# Entrega dos e-mails de produção e desenvolvimento.
# 1) Amazon SES (envio real) quando há AWS_SES_ACCESS_KEY_ID: mesma conta do mewtda-painel, com o
#    domínio chasebrasil.com verificado por DKIM (CNAMEs *._domainkey no DNS do Squarespace).
# 2) Mailtrap, como antes, quando não há SES.
#
# Mailtrap: add-on da Heroku (Email Sandbox). O add-on
# só expõe MAILTRAP_API_TOKEN; as credenciais SMTP vêm da API do Mailtrap (primeira inbox).
# Em dev, sem o token no .env, fica o SMTP local de config/environments/development.rb.
# Atenção: é um sandbox — os e-mails ficam na inbox do Mailtrap e não chegam aos usuários.
# Com MAILTRAP_SENDING_TOKEN definido, usa o Email Sending (envio real) no lugar do sandbox.
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
    if ENV['AWS_SES_ACCESS_KEY_ID'].present?
      self.delivery_method = :ses_v2
      self.ses_v2_settings = {
        region: ENV.fetch('AWS_SES_REGION', 'us-east-1'),
        credentials: Aws::Credentials.new(ENV['AWS_SES_ACCESS_KEY_ID'], ENV['AWS_SES_SECRET_ACCESS_KEY'])
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
