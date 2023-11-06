class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :modal_test

  def index
    orders = Tiny::Orders.get_all_orders('preparando_envio')
    ids_to_reject = Attempt.where(status: :success).pluck(:tiny_order_id).map &:to_s
    @orders = orders['pedidos'].reject { |order| ids_to_reject.include?(order['pedido']['id']) } if orders['pedidos'].present?

    @invoice_emition = Attempt.where(kinds: :create_correios_order, status: 2)
                              .distinct(:order_correios_id)
                              .where.not(order_correios_id: Attempt.where(kinds: :emission_invoice, status: 2).select(:order_correios_id))

    @send_xml = Attempt.where(kinds: :create_correios_order, status: 2)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: Attempt.where(kinds: :send_xml, status: 2).select(:order_correios_id))

    @get_tracking = Attempt.where(kinds: :send_xml, status: 2)
                           .distinct(:order_correios_id)
                           .where.not(order_correios_id: Attempt.where(kinds: :get_tracking, status: 2).select(:order_correios_id))
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
