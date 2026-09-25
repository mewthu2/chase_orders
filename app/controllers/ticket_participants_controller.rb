class TicketParticipantsController < ApplicationController
  include TicketPage

  def create
    return unless load_ticket(params[:ticket_id])

    user = User.find_by(id: params[:user_id])
    result = Tickets::AddFollower.call(ticket: @ticket, user: user, added_by: current_user)
    if result.success?
      redirect_to ticket_path(@ticket), notice: "#{user.name} foi chamado(a) e avisado(a) por e-mail."
    else
      redirect_to ticket_path(@ticket), alert: result.error
    end
  end
end
