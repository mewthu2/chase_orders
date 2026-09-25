class HomeController < ApplicationController
  before_action :authenticate_user!

  SCOPE_TITLES = { 'mine' => 'Meus chamados', 'sectors' => 'Chamados dos meus setores', 'all' => 'Todos os chamados' }.freeze

  # Painel de chamados: "mine" = em que participo; "sectors" = todos dos setores que meus perfis
  # liberam; "all" = tudo (só admin).
  def index
    @sector_ids = current_user.visible_ticket_sector_ids
    @scopes = SCOPE_TITLES.slice(*['mine', ('sectors' if @sector_ids.any?), ('all' if current_user.admin?)].compact)
    @scope = @scopes.key?(params[:scope]) ? params[:scope] : 'mine'
    base = case @scope
           when 'all' then Ticket.all
           when 'sectors' then Ticket.in_sectors(@sector_ids)
           else Ticket.involving(current_user)
           end
    @status_filter = params[:status].presence || 'open'

    @counters = %w[waiting_me waiting_others overdue resolved_week].to_h { |key| [key.to_sym, filter_by_status(base, key).count] }

    tickets = filter_by_status(base, @status_filter)
    tickets = tickets.where(ticket_responsability_id: params[:ticket_responsability_id]) if params[:ticket_responsability_id].present?
    tickets = tickets.in_sectors(params[:ticket_sector_id]) if params[:ticket_sector_id].present?
    if TicketParticipant.roles.key?(params[:role])
      tickets = tickets.where(id: TicketParticipant.where(user_id: current_user.id, role: params[:role]).select(:ticket_id))
    end

    @tickets = tickets.includes({ ticket_responsability: :ticket_sector }, :requester)
                      .recent_activity.paginate(page: params[:page], per_page: 20)
    # "sua vez" da listagem numa query só, com a mesma regra dos contadores.
    @waiting_on_me_ids = waiting_on_me(Ticket.where(id: @tickets.map(&:id))).pluck(:id).to_set
    @responsabilities = TicketResponsability.ordered
    @sectors = TicketSector.where(id: @sector_ids).ordered
  end

  private

  def filter_by_status(scope, filter)
    case filter
    when 'open' then scope.open_tickets
    when 'waiting_me' then scope.where(id: waiting_on_me(scope).select(:id))
    when 'waiting_others' then scope.open_tickets.where.not(id: waiting_on_me(scope).select(:id))
    when 'resolved_week' then scope.where('tickets.resolved_at >= ?', 7.days.ago)
    when 'overdue' then scope.overdue
    when *Ticket.statuses.keys then scope.where(status: filter)
    else scope
    end
  end

  # Abertos em que a vez é minha: sou o solicitante e ele aguarda o solicitante, ou sou
  # responsável e ele aguarda os responsáveis.
  def waiting_on_me(scope)
    responsible_of = TicketParticipant.where(user_id: current_user.id, role: :responsible).select(:ticket_id)
    scope.where(status: :awaiting_requester, requester_id: current_user.id)
         .or(scope.where(status: [:awaiting_responsible, :in_progress], id: responsible_of))
  end
end
