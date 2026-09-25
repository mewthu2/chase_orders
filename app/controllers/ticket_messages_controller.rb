class TicketMessagesController < ApplicationController
  include TicketPage

  def create
    return unless load_ticket(params[:ticket_id])

    message = Tickets::AddMessage.call(ticket: @ticket, author: current_user, body: message_params[:body],
                                       status: message_params[:status], attachments: message_params[:attachments])
    if message.persisted?
      redirect_to ticket_path(@ticket, anchor: "message-#{message.id}"), notice: 'Interação registrada.'
    else
      @ticket.reload
      prepare_ticket_page(message)
      render 'tickets/show', status: :unprocessable_entity
    end
  end

  private

  def message_params
    params.fetch(:ticket_message, {}).permit(:body, :status, attachments: [])
  end
end
