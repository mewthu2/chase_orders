module Users
  # Login. Com a 2 etapas ligada (TwoFactorLogin), a senha certa nunca entra direto: manda o código por
  # e-mail e segue para Users::TwoFactorController.
  class SessionsController < Devise::SessionsController

    def create
      return super unless TwoFactorLogin.enabled?

      user = User.find_for_authentication(email: sign_in_params[:email])
      return super unless user&.valid_password?(sign_in_params[:password]) && user.active_for_authentication?

      user.send_login_code!
      session[:two_factor_login] = { 'user_id' => user.id, 'remember' => sign_in_params[:remember_me] == '1', 'started_at' => Time.current.to_i }
      redirect_to user_two_factor_path
    rescue StandardError => e
      raise unless user && e.class.name.start_with?('Aws::', 'Net::', 'Mail::', 'Errno::')

      Rails.logger.error("[2 etapas] falha ao enviar o código para o usuário #{user.id}: #{e.class}: #{e.message}")
      redirect_to new_user_session_path, alert: 'Não conseguimos enviar o código de verificação agora. Tente de novo em instantes.'
    end
  end
end
