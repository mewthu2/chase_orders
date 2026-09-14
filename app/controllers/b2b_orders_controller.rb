require 'csv'

class B2bOrdersController < ApplicationController
  guard_screen :b2b_orders
  before_action :set_b2b_order, only: [:edit, :update, :transmit]

  def index
    @b2b_orders = B2bOrder.includes(:client, :transfer_location, :user).recent
    @b2b_orders = @b2b_orders.where(status: params[:status]) if params[:status].present?
    @b2b_orders = @b2b_orders.where(kind: params[:kind]) if params[:kind].present?
  end

  def new
    @b2b_order = B2bOrder.new(kind: :sale)
  end

  def create
    @b2b_order = B2bOrder.new(b2b_order_params)
    @b2b_order.user = current_user

    if @b2b_order.save
      redirect_to b2b_orders_path, notice: 'Pedido salvo com sucesso.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @b2b_order.update(b2b_order_params)
      redirect_to b2b_orders_path, notice: 'Pedido atualizado com sucesso.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def transmit
    unless @b2b_order.transmittable?
      redirect_to b2b_orders_path, alert: 'Este pedido não pode ser transmitido.'
      return
    end

    TransmitB2bOrderJob.perform_later(@b2b_order.id)
    redirect_to b2b_orders_path, notice: 'Pedido enviado para transmissão ao Tiny.'
  end

  def shipping_methods
    methods = Rails.cache.fetch('tiny2_shipping_methods', expires_in: 10.minutes) do
      B2bTinyService.new.shipping_methods
    end
    render json: { success: true, shipping_methods: methods }
  end

  def parse_items_spreadsheet
    file = params[:file]
    unless file.present?
      render json: { success: false, message: 'Nenhum arquivo enviado.' }
      return
    end

    csv = CSV.parse(file.read.force_encoding('UTF-8'), headers: true)
    items = csv.filter_map do |row|
      sku = row['SKU']
      quantity = row['Quantidade'].to_i
      next if sku.blank? || quantity <= 0

      product = Product.find_by(sku: sku)
      { sku: sku, name: product&.shopify_product_name, quantity: quantity }
    end

    if items.empty?
      render json: { success: false, message: 'Nenhum item válido encontrado na planilha (colunas esperadas: SKU, Quantidade).' }
    else
      render json: { success: true, items: items }
    end
  rescue StandardError => e
    render json: { success: false, message: "Erro ao processar planilha: #{e.message}" }
  end

  def product_stock
    sku = params[:sku]
    product = Product.find_by(sku: sku)

    unless product&.shopify_variant_id.present?
      render json: { success: true, quantity: 0, status: 'error', message: 'Produto não encontrado' }
      return
    end

    render json: { success: true, **shopify_stock_for(product) }
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = Product.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{query.downcase}%").limit(10)

    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, **shopify_stock_for(p) } } }
  end

  private

  def create_shopify_session
    ShopifyAPI::Auth::Session.new(shop: 'chasebrasil.myshopify.com', access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'))
  end

  def shopify_stock_for(product)
    query = <<~GRAPHQL
      query {
        productVariant(id: "gid://shopify/ProductVariant/#{product.shopify_variant_id}") {
          inventoryQuantity
        }
      }
    GRAPHQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session: create_shopify_session)
    response = client.query(query: query)
    variant = response.body.dig('data', 'productVariant')

    quantity = variant&.dig('inventoryQuantity') || 0
    status = quantity > 10 ? 'high' : (quantity.positive? ? 'low' : 'out')
    { quantity: quantity, status: status }
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#shopify_stock_for exception: #{e.message}"
    { quantity: 0, status: 'error' }
  end

  def set_b2b_order
    @b2b_order = B2bOrder.find(params[:id])
  end

  def b2b_order_params
    params.require(:b2b_order).permit(
      :kind, :status, :client_id, :transfer_location_id, :carrier_name,
      :carrier_shipping_method, :freight_paid_by, :freight_value, :notes,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :_destroy]
    )
  end
end
