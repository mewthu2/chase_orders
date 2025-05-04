class OrdersController < ApplicationController
  before_action :load_form_references, only: [:index]
  before_action :set_order, only: [:show]

  def index
    @orders = Order.includes(:order_items)

    # Filtro por kind
    @orders = @orders.where(kinds: params[:kind]) if params[:kind].present?
    
    # Filtros de integração
    if params[:has_tiny] == "1"
      @orders = @orders.where.not(tiny_order_id: nil)
    end
    
    if params[:has_shopify] == "1"
      @orders = @orders.where.not(shopify_order_id: nil)
    end
    
    if params[:without_shopify] == "1"
      @orders = @orders.where(shopify_order_id: nil)
    end
    
    # Filtros de pesquisa
    @orders = @orders.where('tiny_order_id LIKE ?', "%#{params[:tiny_order_id]}%") if params[:tiny_order_id].present?
    @orders = @orders.where('shopify_order_id LIKE ?', "%#{params[:shopify_order_id]}%") if params[:shopify_order_id].present?
    @orders = @orders.where('tags LIKE ?', "%#{params[:tags]}%") if params[:tags].present?

    @orders = @orders.order(created_at: :desc)
    @orders = @orders.paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
    
    # Estatísticas para os tipos de pedidos
    @kind_stats = {}
    
    # Definimos os três tipos conhecidos
    kinds = ['rj', 'bh_shopping', 'lagoa_seca']
    
    kinds.each do |kind|
      # Contagem total para este kind
      total = Order.where(kinds: kind).count
      
      # Contagem de pedidos com Tiny para este kind
      tiny_count = Order.where(kinds: kind).where.not(tiny_order_id: nil).count
      
      # Contagem de pedidos com Shopify para este kind
      shopify_count = Order.where(kinds: kind).where.not(shopify_order_id: nil).count
      
      # Contagem de pedidos sem Shopify para este kind
      without_shopify_count = Order.where(kinds: kind, shopify_order_id: nil).count
      
      # Armazena as estatísticas
      @kind_stats[kind] = {
        total: total,
        tiny: tiny_count,
        shopify: shopify_count,
        without_shopify: without_shopify_count,
        tiny_percent: total > 0 ? (tiny_count.to_f / total * 100).round : 0,
        shopify_percent: total > 0 ? (shopify_count.to_f / total * 100).round : 0
      }
    end
  end

  def show
    # @order já está definido pelo before_action :set_order
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
