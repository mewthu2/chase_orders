module Whatsapp
  class BaseController < ApplicationController
    protect_from_forgery with: :exception, prepend: true
    before_action :require_active_user
    before_action :private_response
    rescue_from JSON::ParserError, with: -> { render json: { error: 'Parâmetros inválidos.' }, status: :unprocessable_entity }
    rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
    rescue_from ActiveRecord::RecordInvalid, Media::Invalid, ArgumentError, ActionController::ParameterMissing do |error|
      render json: { error: error.is_a?(ActiveRecord::RecordInvalid) ? error.record.errors.full_messages.join(', ') : error.message }, status: :unprocessable_entity
    end

    private
    def require_active_user = (head(:forbidden) unless current_user&.active?)
    def private_response
      response.headers['Cache-Control'] = 'no-store, private'
      response.headers['X-Content-Type-Options'] = 'nosniff'
    end
    def require_attendance
      head :forbidden unless current_user&.can_access_screen?('whatsapp_attend')
    end
    def require_management
      head :forbidden unless Connection.administrable_by?(current_user)
    end
    def authorized_connections = Connection.visible_to(current_user)
    def authorized_conversations = Conversation.visible_to(current_user)
  end
end
