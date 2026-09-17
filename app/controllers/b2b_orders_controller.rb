require 'csv'

class B2bOrdersController < ApplicationController
  guard_screen :b2b_orders
  before_action :set_b2b_order, only: [:edit, :update, :transmit]

  def index
    @b2b_orders = B2bOrder.includes(:client, :transfer_location).recent
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
      { sku: sku, name: product&.shopify_product_name, quantity: quantity,
        suggested_price: suggested_price_for(product),
        image_url: product ? image_url_for(product) : nil }
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

    unless product
      render json: { success: true, quantity: 0, status: 'error', message: 'Produto não encontrado' }
      return
    end

    render json: { success: true, **correios_stock_for(product) }
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = token_search(query).limit(10)

    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, image_url: image_url_for(p), suggested_price: suggested_price_for(p) } } }
  end

  # Modal "Selecionar Produtos" (estilo Shopify): agrupa os SKUs encontrados
  # pelo nome do produto, cada grupo vira "produto" com suas variantes (SKUs).
  def product_picker
    query = params[:query].to_s.strip
    products = query.present? ? token_search(query).limit(300) : Product.order(:shopify_product_name).limit(60)

    grouped = products.group_by { |p| p.shopify_product_name.presence || p.sku }.first(40)

    result = grouped.map do |name, variants|
      {
        name: name,
        image_url: variants.find { |v| v.image_url.present? }&.image_url,
        variants: variants.map do |v|
          {
            id: v.id,
            sku: v.sku,
            option: v.option1.presence || v.sku,
            price: suggested_price_for(v)
          }
        end
      }
    end

    render json: { success: true, products: result }
  end

  def search_client
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    local_clients = Client.where(
      'LOWER(responsible_name) LIKE :q OR LOWER(business_name) LIKE :q OR registration LIKE :q',
      q: "%#{query.downcase}%"
    ).limit(10)

    local_registrations = local_clients.filter_map { |c| c.registration.to_s.gsub(/\D/, '').presence }

    local_results = local_clients.map do |c|
      { source: 'honey', client_id: c.id, name: c.display_name, registration: c.cnpj_formatted }
    end

    tiny_results = B2bTinyService.new.search_clients(query).filter_map do |c|
      digits = c[:registration].to_s.gsub(/\D/, '')
      next if digits.present? && local_registrations.include?(digits)

      {
        source: 'tiny', tiny_id: c[:tiny_id], name: c[:name], registration: c[:registration],
        street: c[:street], number: c[:number], complement: c[:complement],
        neighbourhood: c[:neighbourhood], city: c[:city], state: c[:state], zip: c[:zip],
        email: c[:email], phone: c[:phone]
      }
    end.first(10)

    render json: { success: true, clients: local_results + tiny_results }
  end

  def import_client
    registration = params[:registration].to_s.gsub(/\D/, '')

    client = if registration.present?
               Client.where(
                 "REPLACE(REPLACE(REPLACE(registration, '.', ''), '/', ''), '-', '') = ?",
                 registration
               ).first
             end
    client ||= Client.new(
      responsible_name: params[:name],
      registration: registration.presence,
      street: params[:street],
      number: params[:number],
      neighbourhood: params[:neighbourhood],
      city: params[:city],
      state: params[:state],
      zip: params[:zip],
      email: params[:email],
      phone: params[:phone]
    )

    if client.persisted? || client.save
      render json: { success: true, client: { id: client.id, display_name: client.display_name, registration: client.cnpj_formatted } }
    else
      render json: { success: false, errors: client.errors.full_messages }
    end
  end

  private

  # Busca "inteligente": cada palavra da query precisa aparecer em algum lugar
  # do SKU ou do nome, em qualquer ordem — assim "signature black" encontra
  # "Legging Signature Seamless Black", "Short Signature Black" etc.
  def token_search(query)
    tokens = query.to_s.downcase.split(/\s+/).reject(&:blank?)
    return Product.none if tokens.empty?

    tokens.reduce(Product.all) do |scope, token|
      scope.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
    end
  end

  def suggested_price_for(product)
    return nil unless product&.price.present?

    (product.price.to_f * 0.4).round(2)
  end

  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil unless product.shopify_product_id.present?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url
  end

  def correios_stock_for(product)
    response = Correios::Orders.get_stock(product.sku, from_tiny2: true)
    return { quantity: 0, status: 'error' } unless response.respond_to?(:success?) && response.success?

    quantity = JSON.parse(response.body)['disponivel'].to_i
    status = quantity > 10 ? 'high' : (quantity.positive? ? 'low' : 'out')
    { quantity: quantity, status: status }
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#correios_stock_for exception: #{e.message}"
    { quantity: 0, status: 'error' }
  end

  def set_b2b_order
    @b2b_order = B2bOrder.find(params[:id])
  end

  def b2b_order_params
    params.require(:b2b_order).permit(
      :kind, :status, :client_id, :transfer_location_id, :carrier_id, :carrier_name,
      :carrier_shipping_method, :freight_paid_by, :freight_value, :notes,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :_destroy]
    )
  end
end
