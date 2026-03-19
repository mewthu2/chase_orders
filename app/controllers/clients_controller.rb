# app/controllers/clients_controller.rb
class ClientsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_client, only: [:show, :edit, :update, :destroy]

  def index
    @clients = Client.order(:responsible_name)
    @clients = @clients.where(
      'LOWER(responsible_name) LIKE :q OR LOWER(business_name) LIKE :q OR registration LIKE :q',
      q: "%#{params[:q]&.downcase}%"
    ) if params[:q].present?
  end

  def show; end

  def new
    @client = Client.new
  end

  def edit; end

  def create
    @client = Client.new(client_params)
    if @client.save
      respond_to do |format|
        format.html { redirect_to clients_path, notice: 'Cliente cadastrado com sucesso.' }
        format.json { render json: { success: true, client: client_json(@client) } }
      end
    else
      respond_to do |format|
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { success: false, errors: @client.errors.full_messages } }
      end
    end
  end

  def update
    if @client.update(client_params)
      redirect_to clients_path, notice: 'Cliente atualizado com sucesso.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @client.destroy
    redirect_to clients_path, notice: 'Cliente removido.'
  end

  def search
    query = params[:q]&.strip
    clients = if query.present?
                Client.where(
                  'LOWER(responsible_name) LIKE :q OR LOWER(business_name) LIKE :q OR registration LIKE :q',
                  q: "%#{query.downcase}%"
                ).limit(10)
              else
                Client.order(:responsible_name).limit(10)
              end

    render json: { success: true, clients: clients.map { |c| client_json(c) } }
  end

  private

  def set_client
    @client = Client.find(params[:id])
  end

  def client_params
    params.require(:client).permit(
      :responsible_name, :business_name, :registration,
      :state_registration, :municipal_registration,
      :street, :neighbourhood, :number, :city, :state, :zip,
      :email, :phone
    )
  end

  def client_json(client)
    {
      id: client.id,
      responsible_name: client.responsible_name,
      business_name: client.business_name,
      display_name: client.display_name,
      registration: client.cnpj_formatted,
      state_registration: client.state_registration,
      municipal_registration: client.municipal_registration,
      street: client.street,
      neighbourhood: client.neighbourhood,
      number: client.number,
      city: client.city,
      state: client.state,
      zip: client.zip,
      email: client.email,
      phone: client.phone
    }
  end
end