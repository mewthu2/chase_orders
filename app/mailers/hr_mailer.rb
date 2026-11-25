# Avisos do RH: jornada acima da carga horária ou fora dos limites da CLT (Hr::JourneyCheck).
# Destinatários em HR_ALERT_EMAILS (vírgula), padrão atendimento@chasebrasil.com.
class HrMailer < ApplicationMailer
  layout 'hr_mailer'

  def self.recipients = ENV.fetch('HR_ALERT_EMAILS', 'atendimento@chasebrasil.com').split(',').map(&:strip).reject(&:blank?)

  def journey_alert
    @alerts = params[:alerts]
    @employee = @alerts.first.employee
    @severe = @alerts.any? { |a| a.tone == 'red' }
    attachments.inline['chase-logo.png'] = File.binread(TicketMailer::LOGO_PATH)
    subject = if @alerts.one?
                "#{@alerts.first.emoji} #{@employee.name}: #{@alerts.first.label.downcase}"
              else
                "⚠️ #{@employee.name}: #{@alerts.size} alertas de jornada"
              end
    mail(to: self.class.recipients, subject: subject)
  end
end
