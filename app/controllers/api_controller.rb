class ApiController < ApplicationController
  skip_before_action :verify_authenticity_token

  def add_packaging
    unless params[:token] == ENV['FLOW_SECRET_TOKEN']
      render json: { error: 'Unauthorized' }, status: :unauthorized and return
    end

    render json: { success: true }
  end
end
