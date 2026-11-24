# Verificação em 2 etapas por e-mail no login: depois da senha certa, um código de 6 dígitos vai para o
# e-mail da pessoa (AuthMailer#login_code) e só com ele o login termina (Users::TwoFactorController).
# Liga com TWO_FACTOR_LOGIN=on — só com o envio de e-mail de produção funcionando, senão ninguém entra.
module TwoFactorLogin
  extend ActiveSupport::Concern

  CODE_TTL = 10.minutes
  MAX_ATTEMPTS = 5
  RESEND_INTERVAL = 30.seconds
  TRUST_PERIOD = 30.days

  def self.enabled? = ENV['TWO_FACTOR_LOGIN'] == 'on'

  class_methods do
    # Com a 2 etapas ligada, quem redefine a senha volta para o login (senha nova + código):
    # entrar direto pelo link do e-mail pularia a segunda etapa.
    def sign_in_after_reset_password = !TwoFactorLogin.enabled? && super
  end

  def send_login_code!
    code = format('%06d', SecureRandom.random_number(1_000_000))
    update_columns(login_code_digest: login_code_hmac(code), login_code_sent_at: Time.current, login_code_attempts: 0)
    AuthMailer.login_code(self, code).deliver_now
    code
  end

  def login_code_resendable? = login_code_sent_at.nil? || login_code_sent_at <= RESEND_INTERVAL.ago

  # :ok, :invalid ou :expired (vencido ou tentativas esgotadas: só um código novo resolve).
  def check_login_code(code)
    return :expired if login_code_digest.blank? || login_code_sent_at.nil? || login_code_sent_at < CODE_TTL.ago
    return :expired if login_code_attempts >= MAX_ATTEMPTS

    if ActiveSupport::SecurityUtils.secure_compare(login_code_hmac(code.to_s.gsub(/\D/, '')), login_code_digest)
      update_columns(login_code_digest: nil, login_code_attempts: 0)
      :ok
    else
      update_columns(login_code_attempts: login_code_attempts + 1)
      login_code_attempts >= MAX_ATTEMPTS ? :expired : :invalid
    end
  end

  # Valor do cookie "confiar neste navegador": deriva da senha, então trocar a senha desconfia de todos.
  def trusted_login_token = login_code_hmac("trust:#{authenticatable_salt}")

  private

  def login_code_hmac(value) = OpenSSL::HMAC.hexdigest('SHA256', Rails.application.secret_key_base, "#{id}:#{value}")
end
