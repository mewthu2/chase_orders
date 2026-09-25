class TicketsController < ApplicationController
  include TicketPage

  before_action :admin_only!, only: :destroy

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
  def load_form_options
    @sector_responsabilities = TicketResponsability.active.includes(:users).ordered
                                                   .where(ticket_sector_id: TicketSector.active.where(id: current_user.visible_ticket_sector_ids).select(:id))
                                                   .to_a
    @responsabilities = @sector_responsabilities.select { |r| r.users.any? { |user| user.active? && (user != current_user || current_user.admin?) } }
    @users = User.active.where.not(id: current_user.id).order(:name)
  end

  # O setor só aparece no select do formulário: carrega só quando ele vai ser renderizado.
  def render_form(status: :ok)
    ActiveRecord::Associations::Preloader.new(records: @responsabilities, associations: :ticket_sector).call
    render :new, status: status
  end
end
