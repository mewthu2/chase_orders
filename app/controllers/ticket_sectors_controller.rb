class TicketSectorsController < ApplicationController
  before_action :admin_only!
  before_action :set_sector, only: [:edit, :update, :destroy]

  def index
    @sectors = TicketSector.includes(:ticket_responsabilities, :profiles).ordered
  end

  def new
    @sector = TicketSector.new
  end

  def create
    @sector = TicketSector.new(sector_params)
    if @sector.save
      redirect_to ticket_sectors_path, notice: 'Setor criado.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @sector.update(sector_params)
      redirect_to ticket_sectors_path, notice: 'Setor atualizado.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @sector.destroy
      redirect_to ticket_sectors_path, notice: 'Setor excluído.'
    else
      redirect_to ticket_sectors_path, alert: 'Este setor tem responsabilidades. Desative-o em vez de excluir.'
    end
  end

  private

  def set_sector
    @sector = TicketSector.find(params[:id])
  end

  def sector_params
    params.require(:ticket_sector).permit(:name, :description, :active)
  end
end
