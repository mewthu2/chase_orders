# E-mails do Devise (redefinição de senha e aviso de senha alterada) com o visual dos e-mails do sistema.
class AuthMailer < Devise::Mailer
  layout 'auth_mailer'
  default template_path: 'devise/mailer'

  protected

  def devise_mail(record, action, opts = {}, &block)
    attachments.inline['chase-logo.png'] = File.binread(TicketMailer::LOGO_PATH)
    super
  end
end
