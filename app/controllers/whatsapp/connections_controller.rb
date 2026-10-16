module Whatsapp
  class ConnectionsController < BaseController
    before_action :require_management
    def index
      @connections = Connection.order(:name)
      @users = User.active.order(:name).select { |u| u.can_access_screen?('whatsapp_attend') }
      respond_to do |format|
        format.html
        format.json { render json: { connections: @connections.map { |c| payload(c) }, configured: Providers::Evolution.configured? } }
      end
    end

    def create
      raise ArgumentError, 'A integração ainda precisa ser configurada pela administração.' unless Providers::Evolution.configured?
      users = permitted_users(params[:user_ids])
      connection = Connection.new(name: params.require(:name))
      Connection.transaction do
        connection.save!
        connection.users = users
      end
      connection.request_control!('connect')
      render json: payload(connection), status: :created
    end

    def update
      connection = Connection.find(params[:id])
      connection.with_lock do
        connection.update!(name: params.require(:name))
        connection.users = permitted_users(params[:user_ids])
      end
      render json: payload(connection)
    end

    def connect
      connection = Connection.find(params[:id])
      connection.request_control!('connect')
      render json: payload(connection), status: :accepted
    end

    def disconnect
      connection = Connection.find(params[:id])
      connection.request_control!('disconnect')
      render json: payload(connection), status: :accepted
    end

    def sync
      connection = Connection.find(params[:id])
      if !connection.sync_requested_at || connection.sync_requested_at < 30.seconds.ago
        connection.update!(sync_requested_at: Time.current)
        SyncJob.perform_later(connection.id)
      end
      head :accepted
    end

    private
    def permitted_users(ids)
      users = User.active.where(id: Array(ids)).to_a
      raise ArgumentError, 'Selecione somente usuários com permissão para atendimento.' unless users.all? { |u| u.can_access_screen?('whatsapp_attend') }
      users
    end
    def payload(connection)
      connection.slice(:id, :name, :phone, :state, :enabled, :provider_updated_at, :last_synced_at, :error_code).merge(
        qr: connection.current_qr, qr_expires_at: connection.qr_expires_at, user_ids: connection.users.ids)
    end
  end
end
