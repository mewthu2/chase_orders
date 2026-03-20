class OrderPdvsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_order_pdv, only: [:show, :edit, :update, :integrate, :add_product, :remove_product, :items, :integrate_tiny, :mark_as_paid, :attach_client, :generate_pdf]

  def index
    @order_pdvs = OrderPdv.includes(:user, :client)
                          .recent

    @order_pdvs = @order_pdvs.paginate(page: params[:page], per_page: params_per_page(params[:per_page]))

    @status_counts = {
      all: OrderPdv.count,
      pending: OrderPdv.pending.count,
      integrated: OrderPdv.integrated.count
    }
  end

  def show
    @items = @order_pdv.order_pdv_items.includes(:product)
  end

  def edit
    @items = @order_pdv.order_pdv_items.includes(:product)
    @address_parts = parse_address(@order_pdv)
  end

  def update
    address1 = build_address1(params[:order_pdv])
    address2 = build_address2(params[:order_pdv])

    order_params = order_pdv_params.merge(address1:, address2:)

    if @order_pdv.update(order_params)
      recalculate_totals
      redirect_to @order_pdv, notice: 'Pedido atualizado com sucesso!'
    else
      @items = @order_pdv.order_pdv_items.includes(:product)
      @address_parts = parse_address(@order_pdv)
      render :edit
    end
  end

  def integrate
    result = ShopifyIntegrationService.new(@order_pdv).integrate

    if result[:success]
      @order_pdv.update!(
        status: 'integrated',
        shopify_order_id: result[:order_id],
        shopify_order_number: result[:order_number],
        integrated_at: Time.current,
        integration_error: nil
      )

      if request.xhr? || request.format.json?
        render json: { success: true, message: 'Pedido integrado com sucesso ao Shopify!', order_number: result[:order_number] }
      else
        redirect_to @order_pdv, notice: 'Pedido integrado com sucesso ao Shopify!'
      end
    else
      @order_pdv.update!(
        status: 'error',
        integration_error: result[:error],
        integration_attempts: @order_pdv.integration_attempts + 1
      )

      if request.xhr? || request.format.json?
        render json: { success: false, message: "Erro na integração: #{result[:error]}" }
      else
        redirect_to @order_pdv, alert: "Erro na integração: #{result[:error]}"
      end
    end
  rescue StandardError => e
    @order_pdv.update!(
      status: 'error',
      integration_error: e.message,
      integration_attempts: @order_pdv.integration_attempts + 1
    )

    if request.xhr? || request.format.json?
      render json: { success: false, message: "Erro na integração: #{e.message}" }
    else
      redirect_to @order_pdv, alert: "Erro na integração: #{e.message}"
    end
  end

  def search_product
    query = params[:query]

    unless query.present?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = Product.where(
      'LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q',
      q: "%#{query.downcase}%"
    ).limit(10)

    products_data = []

    begin
      session = create_shopify_session

      products.each do |product|
        stock_info = get_product_stock(product, session)
        products_data << {
          id: product.id,
          shopify_variant_id: product.shopify_variant_id,
          sku: product.sku,
          name: product.shopify_product_name,
          price: product.price.to_f,
          option1: product.option1,
          image_url: product.image_url,
          stock: stock_info[:quantity],
          stock_status: stock_info[:status],
          stock_message: stock_info[:message]
        }
      end
    rescue StandardError => e
      Rails.logger.error "Erro ao buscar estoque: #{e.message}"

      products_data = products.map do |product|
        {
          id: product.id,
          shopify_variant_id: product.shopify_variant_id,
          sku: product.sku,
          name: product.shopify_product_name,
          price: product.price.to_f,
          option1: product.option1,
          image_url: product.image_url,
          stock: 0,
          stock_status: 'error',
          stock_message: 'Erro ao verificar estoque'
        }
      end
    end

    render json: { success: true, products: products_data }
  end

  def add_product
    product_id = params[:product_id]
    quantity   = params[:quantity].to_i

    # Tenta buscar por ID do banco ou por shopify_variant_id
    product = Product.find_by(id: product_id) ||
              Product.find_by(shopify_variant_id: product_id)

    unless product
      render json: { success: false, message: 'Produto não encontrado' }
      return
    end

    existing_item = @order_pdv.order_pdv_items.find_by(product:)

    if existing_item
      new_qty = existing_item.quantity + quantity
      existing_item.update_columns(
        quantity: new_qty,
        total:    existing_item.price.to_f * new_qty
      )
    else
      @order_pdv.order_pdv_items.create!(
        product:,
        sku:          product.sku,
        product_name: product.shopify_product_name,
        price:        product.price,
        quantity:,
        total:        product.price * quantity,
        option1:      product.option1,
        image_url:    product.image_url
      )
    end

    # update_columns pula validações, incluindo validate_parcels_total
    recalculate_totals_columns

    render json: {
      success: true,
      message: 'Produto adicionado ao pedido',
      total: @order_pdv.reload.formatted_total
    }
  rescue StandardError => e
    Rails.logger.error "Erro em add_product: #{e.message}"
    render json: { success: false, message: e.message }
  end

  def remove_product
    item_id = params[:item_id]
    item    = @order_pdv.order_pdv_items.find_by(id: item_id)

    unless item
      render json: { success: false, message: 'Item não encontrado' }
      return
    end

    item.destroy!
    recalculate_totals_columns

    render json: {
      success: true,
      message: 'Item removido do pedido',
      total: @order_pdv.reload.formatted_total
    }
  rescue StandardError => e
    render json: { success: false, message: e.message }
  end

  def items
    items_data = @order_pdv.order_pdv_items.includes(:product).map do |item|
      image = item.image_url.presence

      # Se não tem imagem salva no item, busca via Shopify e cacheia
      if image.blank? && item.product.present?
        image = ShopifyIntegrationService.get_product_image_from_shopify(item.product)
        item.update_column(:image_url, image) if image.present?
      end

      {
        id:           item.id,
        sku:          item.sku,
        product_name: item.product_name,
        quantity:     item.quantity,
        price:        item.price.to_f,
        total:        item.total.to_f,
        image_url:    image
      }
    end

    render json: {
      success: true,
      items:   items_data,
      total:   @order_pdv.reload.total_price.to_f
    }
  end

  def generate_pdf
    @items    = @order_pdv.order_pdv_items.includes(:product)
    @parcelas = @order_pdv.order_parcels rescue []
    filename  = "pedido_#{@order_pdv.id}_#{Date.today.strftime('%Y%m%d')}"

    respond_to do |format|
      format.pdf do
        render pdf:         filename,
               layout:      'pdf',
               disposition: 'attachment',
               page_size:   'A4',
               margin:      { top: 10, bottom: 10, left: 10, right: 10 }
      end
    end
  end

  def integrate_tiny
    if @order_pdv.tiny_order_id.present?
      render json: { success: false, message: "Pedido já integrado no Tiny (##{@order_pdv.tiny_order_id})" }
      return
    end

    TinyIntegrationJob.perform_later(@order_pdv.id)

    render json: {
      success: true,
      message: 'Integração com Tiny iniciada! O pedido será criado em instantes.'
    }
  rescue StandardError => e
    Rails.logger.error "integrate_tiny error: #{e.message}"
    render json: { success: false, message: "Erro ao enfileirar integração: #{e.message}" }
  end

  def mark_as_paid
    if @order_pdv.status == 'paid'
      render json: { success: false, message: 'Pedido já está marcado como pago.' }
      return
    end

    # Se tem tiny_order_id, aprova no Tiny de forma síncrona
    if @order_pdv.tiny_order_id.present?
      service = TinyService.new
      result  = service.approve_order(@order_pdv.tiny_order_id)

      unless result[:success]
        render json: { success: false, message: "Erro ao aprovar no Tiny: #{result[:error]}" }
        return
      end

      @order_pdv.update_columns(
        status:      'paid',
        tiny_status: 'aprovado',
        tiny_error:  nil
      )
    else
      # Sem Tiny: marca apenas como pago no sistema
      @order_pdv.update_columns(status: 'paid')
    end

    render json: { success: true, message: 'Pedido marcado como pago!' }
  rescue StandardError => e
    Rails.logger.error "mark_as_paid error: #{e.message}"
    render json: { success: false, message: "Erro: #{e.message}" }
  end

  def attach_client
    client_id = params[:client_id]

    if client_id.present?
      client = Client.find_by(id: client_id)
      unless client
        render json: { success: false, message: 'Cliente não encontrado.' }
        return
      end
      @order_pdv.update_columns(client_id: client.id)
    else
      @order_pdv.update_columns(client_id: nil)
    end

    render json: { success: true }
  rescue StandardError => e
    render json: { success: false, message: e.message }
  end

  private

  def set_order_pdv
    @order_pdv = OrderPdv.includes(:client, :order_pdv_items, :order_parcels).find(params[:id])
  end

  def order_pdv_params
    params.require(:order_pdv).permit(
      :client_id,
      :customer_name, :customer_email, :customer_phone, :customer_cpf,
      :street, :number, :complement, :neighborhood, :city, :state, :zip,
      :store_type, :payment_method, :discount_amount, :discount_reason, :notes
    )
  end

  def build_address1(params)
    [params[:street], params[:number]].select(&:present?).join(', ')
  end

  def build_address2(params)
    [params[:complement], params[:neighborhood]].select(&:present?).join(', ')
  end

  def parse_address(order_pdv)
    address1_parts = order_pdv.address1&.split(', ') || []
    address2_parts = order_pdv.address2&.split(', ') || []

    {
      street:       address1_parts[0] || '',
      number:       address1_parts[1] || '',
      complement:   address2_parts[0] || '',
      neighborhood: address2_parts[1] || ''
    }
  end

  def params_per_page(per_page_param)
    per_page = per_page_param.to_i
    per_page.positive? ? per_page : 20
  end

  # Usa update_columns para pular todas as validações (inclusive validate_parcels_total)
  def recalculate_totals_columns
    @order_pdv.order_pdv_items.each do |item|
      item.update_column(:total, item.price.to_f * item.quantity)
    end

    subtotal    = @order_pdv.order_pdv_items.sum(:total)
    total_price = subtotal - (@order_pdv.discount_amount.to_f)

    @order_pdv.update_columns(subtotal:, total_price:)
  end

  # Usado apenas no update (via form), onde a validação de parcelas é desejada
  def recalculate_totals
    @order_pdv.order_pdv_items.each do |item|
      item.update_column(:total, item.price.to_f * item.quantity)
    end

    subtotal    = @order_pdv.order_pdv_items.sum(:total)
    total_price = subtotal - (@order_pdv.discount_amount.to_f)

    @order_pdv.update_columns(subtotal:, total_price:)
  end

  def create_shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP')
    )
  end

  def get_product_stock(product, session)
    query = <<~GRAPHQL
      query {
        productVariant(id: "gid://shopify/ProductVariant/#{product.shopify_variant_id}") {
          id
          sku
          inventoryQuantity
        }
      }
    GRAPHQL

    client   = ShopifyAPI::Clients::Graphql::Admin.new(session:)
    response = client.query(query:)
    variant  = response.body.dig('data', 'productVariant')

    unless variant
      return { quantity: 0, status: 'error', message: 'Variante não encontrada' }
    end

    quantity = variant['inventoryQuantity'] || 0
    status   = quantity > 10 ? 'high' : (quantity.positive? ? 'low' : 'out')
    message  = quantity > 10 ? "Estoque: #{quantity} unidades" :
               (quantity.positive? ? "Estoque baixo: #{quantity} unidades" : 'Sem estoque (0 unidades)')

    { quantity:, status:, message: }
  rescue StandardError => e
    Rails.logger.error "Erro ao buscar estoque do produto #{product.id}: #{e.message}"
    { quantity: 0, status: 'error', message: 'Erro ao verificar estoque' }
  end
end
