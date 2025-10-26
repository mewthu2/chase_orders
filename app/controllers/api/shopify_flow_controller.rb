class Api::ShopifyFlowController < ApplicationController
  include JwtAuth
  skip_before_action :verify_authenticity_token

  def add_packaging
    order_id = params[:order_id]
    return render json: { error: 'order_id ausente' }, status: :bad_request if order_id.blank?

    result = ShopifyPackagingService.new(order_id).run
    render json: result
  end
end
