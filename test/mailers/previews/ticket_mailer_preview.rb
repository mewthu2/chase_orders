# Visualize em /rails/mailers/ticket_mailer (usa o último chamado existente).
class TicketMailerPreview < ActionMailer::Preview
  def opened = TicketMailer.with(ticket: ticket, recipient: ticket.requester).opened
  def new_message = TicketMailer.with(ticket: ticket, recipient: ticket.requester, message: ticket.messages.comment.last || ticket.messages.build(user: ticket.requester, body: 'Exemplo de interação')).new_message
  def follower_added = TicketMailer.with(ticket: ticket, recipient: ticket.requester, added_by: ticket.requester).follower_added
  def overdue = TicketMailer.with(ticket: ticket, recipient: ticket.requester).overdue

  private

  def ticket = Ticket.last || raise('Abra um chamado antes de ver os previews')
end
