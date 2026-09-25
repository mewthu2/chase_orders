# Avisa por e-mail os chamados que passaram do prazo de resposta. Cada vencimento gera um
# único aviso: overdue_notified_at é zerado quando alguém interage (Tickets::AddMessage).
# Agendado pelo Heroku Scheduler via `rake tickets:notify_overdue` (a cada 10 minutos).
class TicketOverdueJob < ApplicationJob
  queue_as :default

  def perform
    Ticket.pending_overdue_notification.includes(:requester, participants: :user).find_each do |ticket|
      TicketNotifier.overdue(ticket)
      ticket.update_columns(overdue_notified_at: Time.current)
    end
  end
end
