module Whatsapp
  class HealthController < BaseController
    before_action :require_management
    def show
      render json: { configured: Providers::Evolution.configured?,
        pending_events: Event.where(processed_at: nil).count,
        failed_events: Event.where(processed_at: nil).where('attempts >= 5').count,
        queued_messages: Message.where(state: 'queued').count,
        uncertain_messages: Message.where(state: 'uncertain').count,
        connections: Connection.order(:id).map { |c| c.slice(:id, :name, :state, :provider_updated_at, :last_synced_at, :error_code) } }
    end
  end
end
