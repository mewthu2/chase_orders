# Carrega o chamado checando acesso e prepara o que a página do chamado precisa — usado
# pelo show e pelos controllers que re-renderizam a página após um erro.
module TicketPage
  extend ActiveSupport::Concern

  private

  def load_ticket(id)
    @ticket = Ticket.find(id)
    return true if @ticket.visible_to?(current_user)

    redirect_to root_path, alert: 'Você não tem acesso a este chamado.'
    false
  end

  def prepare_ticket_page(message = TicketMessage.new)
    @message = message
    ActiveRecord::Associations::Preloader.new(records: [@ticket], associations: [:requester, { participants: :user }]).call
    @messages = @ticket.messages.includes(:user, attachments_attachments: :blob)
    @available_users = User.active.where.not(id: @ticket.participants.map(&:user_id)).order(:name)
  end
end
