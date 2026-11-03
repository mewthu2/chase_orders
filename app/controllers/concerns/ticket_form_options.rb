# Opções do formulário "Abrir chamado" (página e painel lateral da lista de chamados).
module TicketFormOptions
  extend ActiveSupport::Concern

  private

  def load_form_options
    @sector_responsabilities = TicketResponsability.active.includes(:users).ordered
                                                   .where(ticket_sector_id: TicketSector.active.where(id: current_user.visible_ticket_sector_ids).select(:id))
                                                   .to_a
    @responsabilities = @sector_responsabilities.select { |r| r.users.any? { |user| user.active? && (user != current_user || current_user.admin?) } }
    @users = User.active.where.not(id: current_user.id).order(:name)
  end

  # O setor de cada responsabilidade só aparece no formulário: carrega antes de desenhar, não ao salvar.
  def preload_form_sectors
    ActiveRecord::Associations::Preloader.new(records: @responsabilities, associations: :ticket_sector).call
  end
end
