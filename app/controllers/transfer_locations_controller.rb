class TransferLocationsController < ApplicationController
  guard_screen :transfer_locations
  before_action :set_transfer_location, only: [:edit, :update, :destroy]

  def index
    @transfer_locations = TransferLocation.order(:name)
  end

  def new
    @transfer_location = TransferLocation.new
  end

  def create
    @transfer_location = TransferLocation.new(transfer_location_params)
    if @transfer_location.save
      redirect_to transfer_locations_path, notice: 'Local de transferência criado com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if @transfer_location.update(transfer_location_params)
      redirect_to transfer_locations_path, notice: 'Local de transferência atualizado com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    if @transfer_location.destroy
      redirect_to transfer_locations_path, notice: 'Local de transferência removido com sucesso.'
    else
      redirect_to transfer_locations_path, alert: @transfer_location.errors.full_messages.to_sentence
    end
  end

  private

  def set_transfer_location
    @transfer_location = TransferLocation.find(params[:id])
  end

  def transfer_location_params
    params.require(:transfer_location).permit(
      :name, :registration, :state_registration, :street, :number,
      :complement, :neighbourhood, :city, :state, :zip, :active
    )
  end
end
