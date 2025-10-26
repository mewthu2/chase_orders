class Api::AuthController < ApplicationController
  skip_before_action :verify_authenticity_token

  def login
    user = ApiUser.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      payload = { user_id: user.id, exp: 24.hours.from_now.to_i }
      token = JWT.encode(payload, jwt_secret, 'HS256')
      render json: { token: token }, status: :ok
    else
      render json: { error: 'Invalid credentials' }, status: :unauthorized
    end
  end

  private

  def jwt_secret
    Rails.application.credentials.jwt_secret_key! || ENV.fetch('JWT_SECRET')
  end
end
