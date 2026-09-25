class TicketResponsabilitiesController < ApplicationController
  before_action :admin_only!
  before_action :set_responsability, only: [:edit, :update, :destroy]

  def index
    @responsabilities = TicketResponsability.includes(:users, :ticket_sector).ordered
  end

  def new
    @responsability = TicketResponsability.new(response_time_hours: 24)
  end

  def create
    @responsability = TicketResponsability.new(responsability_params)
    if @responsability.save
      redirect_to ticket_responsabilities_path, notice: 'Responsabilidade criada.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  # user_ids= grava a tabela de ligação na hora; a transação desfaz se a validação falhar.
  def update
    saved = TicketResponsability.transaction do
      @responsability.update(responsability_params) || raise(ActiveRecord::Rollback)
    end

    if saved
      redirect_to ticket_responsabilities_path, notice: 'Responsabilidade atualizada.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @responsability.destroy
      redirect_to ticket_responsabilities_path, notice: 'Responsabilidade excluída.'
    else
      redirect_to ticket_responsabilities_path, alert: 'Esta responsabilidade já tem chamados. Desative-a em vez de excluir.'
    end
  end

  private

  def set_responsability
    @responsability = TicketResponsability.find(params[:id])
  end

  def responsability_params
    params.require(:ticket_responsability).permit(:name, :description, :response_time_hours, :active, :ticket_sector_id, user_ids: [])
  end
end
