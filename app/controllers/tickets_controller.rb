class TicketsController < ApplicationController
  include TicketFormOptions
  include TicketPage

  guard_screen :tickets, only: %i[new create destroy]

  def new
    @ticket = Ticket.new(ticket_responsability_id: params[:ticket_responsability_id])
    load_form_options
    render_form
  end

  def create
    load_form_options
    unless @responsabilities.map(&:id).include?(ticket_params[:ticket_responsability_id].to_i)
      @ticket = Ticket.new(ticket_params.except(:attachments))
      @ticket.errors.add(:ticket_responsability, 'não está disponível para você')
      return render_form(status: :unprocessable_entity)
    end

    @ticket = Tickets::Create.call(requester: current_user, attributes: ticket_params, follower_ids: params.dig(:ticket, :follower_ids))
    if @ticket.persisted?
      redirect_to ticket_path(@ticket), notice: 'Chamado aberto. Os responsáveis foram notificados por e-mail.'
    else
      render_form(status: :unprocessable_entity)
    end
  end

  def show
    prepare_ticket_page if load_ticket(params[:id])
  end

  # Só admin exclui; mensagens, participantes e anexos (bucket) vão junto.
  def destroy
    ticket = Ticket.find(params[:id])
    ticket.destroy!
    redirect_to root_path, notice: "Chamado ##{ticket.id} excluído."
  end

  private

  def ticket_params
    params.require(:ticket).permit(:ticket_responsability_id, :title, :description, attachments: [])
  end

  # Só responsabilidades ativas, de setores ativos que o usuário enxerga e com alguém para atender
  # (admin pode abrir mesmo quando o único responsável é ele).
  # O setor só aparece no select do formulário: carrega só quando ele vai ser renderizado.
  def render_form(status: :ok)
    preload_form_sectors
    render :new, status: status
  end
end
