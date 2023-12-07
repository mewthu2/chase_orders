class DashboardController < ApplicationController
  before_action :load_form_references, only: [:index]
  protect_from_forgery except: :modal_test

  def index
    orders = Tiny::Orders.get_all_orders('preparando_envio')
    ids_to_reject = Attempt.where(kinds: :create_correios_order, status: :success).pluck(:tiny_order_id).map &:to_json
    if orders[:numero_paginas].present? && orders[:numero_paginas] != 1 && orders['pedidos'].present?
      @orders = []
      orders[:numero_paginas].times do |page|
        page_orders = Tiny::Orders.get_orders('preparando_envio', page)
        page_orders[:pedidos].each do |order|
          @orders << order
        end
      end
      @all_orders = @orders.reject { |order| ids_to_reject.include?(order['pedido']['id']) }
    else
      @all_orders = orders.deep_symbolize_keys[:pedidos].reject { |order| ids_to_reject.include?(order[:pedido][:id]) }
    end

    @invoice_emition = Attempt.where(kinds: :create_correios_order, status: 2)
                              .distinct(:order_correios_id)
                              .where.not(order_correios_id: Attempt.where(kinds: :emission_invoice, status: 2).pluck(:order_correios_id))

    @send_xml = Attempt.where(kinds: :create_correios_order, status: 2)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: Attempt.where(kinds: :send_xml, status: 2).pluck(:order_correios_id))

    @get_tracking = Attempt.where(kinds: :send_xml, status: 2)
                           .distinct(:order_correios_id)
                           .where.not(order_correios_id: Attempt.where(kinds: :get_tracking, status: 2).pluck(:order_correios_id))
  end

  def tracking
    response = Correios::Orders.get_tracking(params[:tracking_number])
    if response.code == 200
      @tracking = response['rastreio']
    else
      @tracking = nil
    end
    json_response(@tracking)
  end

  def stock
    response = Correios::Orders.get_stock(params[:item_code])
    if response.code == 200
      @stock = response
    else
      @stock = nil
    end
    json_response(@stock)
  end

  def api_correios; end

  def shopify_list
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil-store.myshopify.com',
      access_token: ENV.fetch('SHOPIFY_TOKEN'),
    )
  end

  private

  def load_form_references; end
end
