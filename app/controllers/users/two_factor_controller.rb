module Users
  # Segunda etapa do login: a senha já conferiu em Users::SessionsController e o código foi por e-mail.
  # A pessoa digita o código aqui (ou chega pelo botão do e-mail, com o código já preenchido) e só então entra.
  # Marcando "Lembre-se de mim por 30 dias", este navegador fica dispensado do código nesse período.
  class TwoFactorController < DeviseController
    include TrustedLoginDevice

    PENDING_TTL = 15.minutes

    prepend_before_action :require_no_authentication
    before_action :load_pending_login

    def show; end

    def verify
      case @user.check_login_code(params[:code])
      when :ok
        session.delete(:two_factor_login)
        @user.remember_me = true if @pending['remember']
        sign_in(:user, @user)
        trust_login_device!(@user) if params[:trust_device] == '1'
        redirect_to after_sign_in_path_for(@user), notice: I18n.t('devise.sessions.signed_in')
      when :invalid
        render_show_with('Código incorreto. Confira o último e-mail que enviamos e tente de novo.')
      else
        render_show_with('Esse código venceu ou teve tentativas erradas demais. Peça um novo abaixo.')
      end
    end

    def resend
      return redirect_to(user_two_factor_path, alert: 'Aguarde alguns segundos antes de pedir outro código.') unless @user.login_code_resendable?

      @user.send_login_code!
      redirect_to user_two_factor_path, notice: "Enviamos um novo código para #{helpers.masked_email(@user.email)}."
    rescue StandardError => e
      raise unless e.class.name.start_with?('Aws::', 'Net::', 'Mail::', 'Errno::')

      Rails.logger.error("[2 etapas] falha ao reenviar o código para o usuário #{@user.id}: #{e.class}: #{e.message}")
      redirect_to user_two_factor_path, alert: 'Não conseguimos enviar o código agora. Tente de novo em instantes.'
    end

    private

    def load_pending_login
      @pending = session[:two_factor_login]
      @user = User.find_by(id: @pending['user_id']) if @pending.is_a?(Hash)
      return if @user&.active_for_authentication? && Time.zone.at(@pending['started_at'].to_i) > PENDING_TTL.ago

      session.delete(:two_factor_login)
      redirect_to new_user_session_path, alert: 'Sua verificação expirou. Entre com e-mail e senha de novo.'
    end

    def render_show_with(message)
      flash.now[:alert] = message
      render :show, status: :unprocessable_entity
    end
  end
end
