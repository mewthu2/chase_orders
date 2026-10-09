class CarriersController < ApplicationController
  guard_screen :carriers
  before_action :set_carrier, only: [:edit, :update, :destroy]

  def index
    @carriers = Carrier.order(:name)
  end

  def new
    @carrier = Carrier.new
  end

  def create
    @carrier = Carrier.new(carrier_params)
    if @carrier.save
      redirect_to carriers_path, notice: 'Transportadora criada com sucesso.'
    else
      render :new
    end
  end

  def edit; end

  def update
    if @carrier.update(carrier_params)
      redirect_to carriers_path, notice: 'Transportadora atualizada com sucesso.'
    else
      render :edit
    end
  end

  def destroy
    if @carrier.destroy
      redirect_to carriers_path, notice: 'Transportadora removida com sucesso.'
    else
      redirect_to carriers_path, alert: @carrier.errors.full_messages.to_sentence
    end
  end

  private

  def set_carrier
    @carrier = Carrier.find(params[:id])
  end

  def carrier_params
    params.require(:carrier).permit(
      :name, :registration, :state_registration, :street, :number,
      :complement, :neighbourhood, :city, :state, :zip, :phone, :email, :active
    )
  end
end
