# Cookie criptografado com os usuários que marcaram "confiar neste navegador" na 2 etapas
# ({ user_id => User#trusted_login_token }): nesses, o login pede só a senha por TwoFactorLogin::TRUST_PERIOD.
module TrustedLoginDevice
  COOKIE = :honey_trusted_login

  private

  def trusted_login_device?(user)
    token = trusted_login_tokens[user.id.to_s]
    token.present? && ActiveSupport::SecurityUtils.secure_compare(token, user.trusted_login_token)
  end

  def trust_login_device!(user)
    cookies.encrypted[COOKIE] = {
      value: trusted_login_tokens.merge(user.id.to_s => user.trusted_login_token),
      expires: TwoFactorLogin::TRUST_PERIOD.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax
    }
  end

  def trusted_login_tokens
    tokens = cookies.encrypted[COOKIE]
    tokens.is_a?(Hash) ? tokens : {}
  end
end
