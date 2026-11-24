# E-mails do Devise (redefinição de senha e aviso de senha alterada) com o visual dos e-mails do sistema.
class AuthMailer < Devise::Mailer
  layout 'auth_mailer'
  default template_path: 'devise/mailer'

  # Código da verificação em 2 etapas (TwoFactorLogin).
  def login_code(record, code)
    @code = code
    devise_mail(record, :login_code, subject: "#{code} é o seu código de acesso ao Honey")
  end

  protected

  def devise_mail(record, action, opts = {}, &block)
    attachments.inline['chase-logo.png'] = File.binread(TicketMailer::LOGO_PATH)
    super
  end
end
