# Decide quem recebe cada e-mail de chamado. Só notifica quem está ativo, com e-mail e com
# as notificações de chamado ligadas (o admin desliga na edição do usuário).
class TicketNotifier
  def self.ticket_opened(ticket)
    recipients(ticket).each { |user| deliver(:opened, ticket: ticket, recipient: user) }
  end

  # Todos os participantes, inclusive o autor (vale como confirmação do que ele registrou).
  def self.message_created(message)
    ticket = message.ticket
    recipients(ticket).each do |user|
      deliver(:new_message, ticket: ticket, recipient: user, message: message)
    end
  end

  def self.follower_added(ticket, follower, added_by:)
    return unless follower.ticket_notifications?

    deliver(:follower_added, ticket: ticket, recipient: follower, added_by: added_by)
  end

  # Avisa quem está com a vez; se a vez é dos responsáveis, o solicitante também fica sabendo.
  def self.overdue(ticket)
    users = ticket.waiting_on_users
    users += [ticket.requester] unless ticket.awaiting_requester?
    users.uniq.select(&:ticket_notifications?).each { |user| deliver(:overdue, ticket: ticket, recipient: user) }
  end

  def self.recipients(ticket)
    TicketParticipant.where(ticket: ticket).includes(:user).map(&:user).uniq
                     .select(&:ticket_notifications?)
  end
  private_class_method :recipients

  def self.deliver(action, **params)
    TicketMailer.with(**params).public_send(action).deliver_later
  end
  private_class_method :deliver
end
