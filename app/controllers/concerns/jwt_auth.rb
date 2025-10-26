module JwtAuth
  extend ActiveSupport::Concern

  included do
    before_action :authorize_request
  end

  private

  def authorize_request
    header = request.headers['Authorization']
    header = header.split(' ').last if header.present?

    begin
      decoded = JWT.decode(header, jwt_secret, true, algorithm: 'HS256')
      @current_api_user = ApiUser.find(decoded[0]['user_id'])
    rescue JWT::DecodeError, ActiveRecord::RecordNotFound
      render json: { error: 'Unauthorized' }, status: :unauthorized
    end
  end

  def jwt_secret
    Rails.application.credentials.jwt_secret_key! || ENV['JWT_SECRET']
  end
end
