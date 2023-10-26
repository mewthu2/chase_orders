class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]

  def index
    orders = Tiny::Orders.get_all_orders('preparando_envio')
    ids_to_reject = Attempt.where(status: :success).pluck(:tiny_order_id).map &:to_s
    @orders = orders['pedidos'].reject { |order| ids_to_reject.include?(order['pedido']['id']) } if orders['pedidos'].present?
  end

  def orders_tiny
    @orders = Tiny::Orders.get_all_orders(params[:situacao])
    respond_to do |f|
      f.js { render layout: false, content_type: 'text/javascript' }
      f.html
    end
  end

  def tracking
    tracking_number = params[:tracking_number]
    response = Correios::Orders.get_tracking(tracking_number)
    if response.code == 200
      @tracking = response['rastreio']
    else
      @tracking = nil
    end
    json_response(@tracking)
  end

  private

  def load_form_references; end
end
