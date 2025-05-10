class OrdersController < ApplicationController
  before_action :load_form_references, only: [:index]
  before_action :set_order, only: [:show]

  def index
    @orders = Order.includes(:order_items)

    @orders = @orders.where(kinds: params[:kind]) if params[:kind].present?

    if params[:has_tiny] == '1'
      @orders = @orders.where.not(tiny_order_id: nil)
    end

    if params[:has_shopify] == '1'
      @orders = @orders.where.not(shopify_order_id: nil)
    end

    if params[:without_shopify] == '1'
      @orders = @orders.where(shopify_order_id: nil)
    end

    if params[:start_date].present? && params[:end_date].present?
      start_date = Date.parse(params[:start_date]) rescue nil
      end_date = Date.parse(params[:end_date]) rescue nil

      if start_date && end_date
        @orders = @orders.where(tiny_creation_date: start_date.beginning_of_day..end_date.end_of_day)
      end
    end

    @orders = @orders.where('tiny_order_id LIKE ?', "%#{params[:tiny_order_id]}%") if params[:tiny_order_id].present?
    @orders = @orders.where('shopify_order_id LIKE ?', "%#{params[:shopify_order_id]}%") if params[:shopify_order_id].present?
    @orders = @orders.where('tags LIKE ?', "%#{params[:tags]}%") if params[:tags].present?

    @orders = @orders.order(tiny_creation_date: :desc)
    @orders = @orders.paginate(page: params[:page], per_page: params_per_page(params[:per_page]))

    @kind_stats = {}

    kinds = ['rj', 'bh_shopping', 'lagoa_seca']

    kinds.each do |kind|
      total = Order.where(kinds: kind).count

      tiny_count = Order.where(kinds: kind).where.not(tiny_order_id: nil).count

      shopify_count = Order.where(kinds: kind).where.not(shopify_order_id: nil).count

      without_shopify_count = Order.where(kinds: kind, shopify_order_id: nil).count

      @kind_stats[kind] = {
        total:,
        tiny: tiny_count,
        shopify: shopify_count,
        without_shopify: without_shopify_count,
        tiny_percent: total.positive? ? (tiny_count.to_f / total * 100).round : 0,
        shopify_percent: total.positive? ? (shopify_count.to_f / total * 100).round : 0
      }
    end
  end

  def show
  rescue ActiveRecord::RecordNotFound
    redirect_to orders_path, alert: 'Pedido não encontrado.'
  end

  private

  def set_order
    @order = Order.includes(:order_items).find(params[:id])
  end

  def load_form_references
    @kinds = Order.distinct.pluck(:kinds).compact
  end

  def params_per_page(per_page_param)
    per_page = (per_page_param || 20).to_i
    [10, 20, 50, 100].include?(per_page) ? per_page : 20
  end
end
