class PosController < ApplicationController
  before_action :authenticate_user!

  def index
    @cart_items = session[:cart_items] || []
    @total      = calculate_cart_total(@cart_items)
  end

  def search_product
    Rails.logger.info "PosController#search_product | params: #{params.inspect}"

    query = params[:query]

    if query.blank?
      render json: { success: false, error: 'Query não pode estar vazio' }
      return
    end

    # Busca produtos com imagem real da Shopify
    products_with_images = ShopifyIntegrationService.search_products(query)

    # Enriquece cada produto com estoque em tempo real e preço PDV (50%)
    products_with_stock = products_with_images.map do |product_data|
      stock_result   = StockService.check_stock(product_data[:id], 1)
      stock_quantity = stock_result[:available_quantity] || 0
      stock_status   = if stock_quantity <= 0
                         'out'
                       elsif stock_quantity <= 5
                         'low'
                       else
                         'high'
                       end

      product = Product.find_by(shopify_variant_id: product_data[:id])
      fetch_and_cache_compare_at_price(product)
      pdv_price = calculate_pdv_price(product)

      product_data.merge(
        stock:             stock_quantity,
        stock_status:      stock_status,
        location:          stock_result[:location] || 'Online Store',
        price:             pdv_price,
        original_price:    product&.price.to_f,
        compare_at_price:  product&.compare_at_price.to_f
      )
    end

    Rails.logger.info "Retornando #{products_with_stock.count} produtos"

    render json: { success: true, products: products_with_stock }
  rescue StandardError => e
    Rails.logger.error "Erro na busca de produtos: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, error: e.message }
  end

  def add_to_cart
    product_id = params[:product_id]
    quantity   = params[:quantity].to_i

    if quantity < 1
      render json: { success: false, error: 'Quantidade deve ser maior que zero' }
      return
    end

    product = Product.find_by(shopify_variant_id: product_id)
    unless product
      render json: { success: false, error: 'Produto não encontrado' }
      return
    end

    stock_result = StockService.check_stock(product_id, quantity)
    unless stock_result[:success] && stock_result[:has_sufficient_stock]
      render json: { success: false, error: stock_result[:message] || 'Estoque insuficiente' }
      return
    end

    session[:cart_items] ||= []
    existing_item = session[:cart_items].find { |item| item['product_id'] == product_id }

    if existing_item
      new_quantity = existing_item['quantity'].to_i + quantity

      stock_check = StockService.check_stock(product_id, new_quantity)
      unless stock_check[:success] && stock_check[:has_sufficient_stock]
        render json: {
          success: false,
          error: "Estoque insuficiente para quantidade total (#{new_quantity}). Disponível: #{stock_check[:available_quantity]}"
        }
        return
      end

      existing_item['quantity'] = new_quantity
    else
      session[:cart_items] << {
        'product_id' => product_id,
        'sku'        => product.sku,
        'name'       => product.shopify_product_name,
        'price'      => calculate_pdv_price(product),
        'quantity'   => quantity,
        'image_url'  => ShopifyIntegrationService.get_product_image_from_shopify(product)
      }
    end

    total = calculate_cart_total(session[:cart_items])
    render json: { success: true, cart_items: session[:cart_items], total: }
  rescue StandardError => e
    Rails.logger.error "Erro ao adicionar ao carrinho: #{e.message}"
    render json: { success: false, error: e.message }
  end

  def update_cart_quantity
    product_id = params[:product_id]
    quantity   = params[:quantity].to_i

    if quantity < 1
      render json: { success: false, error: 'Quantidade deve ser maior que zero' }
      return
    end

    session[:cart_items] ||= []
    item = session[:cart_items].find { |s| s['product_id'] == product_id }

    unless item
      render json: { success: false, error: 'Item não encontrado no carrinho' }
      return
    end

    stock_result = StockService.check_stock(product_id, quantity)
    unless stock_result[:success] && stock_result[:has_sufficient_stock]
      render json: { success: false, error: stock_result[:message] || 'Estoque insuficiente' }
      return
    end

    item['quantity'] = quantity
    total = calculate_cart_total(session[:cart_items])

    render json: { success: true, cart_items: session[:cart_items], total: }
  rescue StandardError => e
    Rails.logger.error "Erro ao atualizar quantidade: #{e.message}"
    render json: { success: false, error: e.message }
  end

  def remove_from_cart
    product_id = params[:product_id]
    session[:cart_items] ||= []
    session[:cart_items].reject! { |item| item['product_id'] == product_id }

    total = calculate_cart_total(session[:cart_items])
    render json: { success: true, cart_items: session[:cart_items], total: }
  rescue StandardError => e
    Rails.logger.error "Erro ao remover do carrinho: #{e.message}"
    render json: { success: false, error: e.message }
  end

  def clear_cart
    session[:cart_items] = []
    render json: { success: true, cart_items: [], total: 0 }
  rescue StandardError => e
    Rails.logger.error "Erro ao limpar carrinho: #{e.message}"
    render json: { success: false, error: e.message }
  end

  def create_order
    Rails.logger.info "PosController#create_order | params: #{params.inspect}"

    cart_items = session[:cart_items] || []
    if cart_items.empty?
      render json: { success: false, error: 'Carrinho está vazio' }
      return
    end

    subtotal    = calculate_cart_total(cart_items)
    total_price = subtotal

    incomplete = params[:incomplete] == true || params[:incomplete] == 'true'

    order = OrderPdv.new(
      user:            current_user,
      client_id:       params[:client_id].presence,
      customer_name:   params[:customer_name],
      customer_email:  params[:customer_email],
      customer_phone:  params[:customer_phone],
      customer_cpf:    params[:customer_cpf],
      address1:        [params[:street], params[:number]].select(&:present?).join(', ').presence,
      address2:        params[:complement],
      city:            params[:city],
      state:           params[:state],
      zip:             params[:zip],
      store_type:      'online',
      payment_method:  incomplete ? nil : determine_payment_method(params[:payment_parcels]),
      subtotal:        subtotal,
      discount_amount: 0,
      discount_reason: nil,
      total_price:     total_price,
      order_note:      params[:notes],
      status:          incomplete ? 'incomplete' : 'pending'
    )

    ActiveRecord::Base.transaction do
      order.save!

      cart_items.each do |item|
        product = Product.find_by(shopify_variant_id: item['product_id'])
        next unless product

        OrderPdvItem.create!(
          order_pdv:    order,
          product:      product,
          sku:          item['sku'],
          product_name: item['name'],
          quantity:     item['quantity'],
          price:        item['price'],
          total:        item['price'].to_f * item['quantity'].to_i
        )
      end

      unless incomplete
        if params[:payment_parcels].present?
          params[:payment_parcels].each do |parcel_data|
            next if parcel_data[:payment_method].blank? || parcel_data[:amount].blank?

            OrderParcel.create!(
              order_pdv:      order,
              payment_method: parcel_data[:payment_method],
              amount:         parcel_data[:amount].to_f,
              notes:          parcel_data[:notes],
              status:         'pending'
            )
          end
        end
      end
    end

    session[:cart_items] = []

    render json: { success: true, message: 'Pedido criado com sucesso!', order_id: order.id }
  rescue StandardError => e
    Rails.logger.error "Erro ao criar pedido: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, error: e.message }
  end

  private

  # Busca o compare_at_price via Shopify API e cacheia na coluna do produto.
  # Roda apenas se compare_at_price ainda for nil (evita chamadas desnecessárias).
  def fetch_and_cache_compare_at_price(product)
    return unless product
    return if product.respond_to?(:compare_at_price) && !product.compare_at_price.nil?

    config = ShopifyIntegrationService.get_store_config_static('online')
    return unless config&.dig(:access_token)

    session = ShopifyIntegrationService.create_shopify_session_static(config[:access_token])
    client  = ShopifyAPI::Clients::Rest::Admin.new(session:)

    response = client.get(path: "variants/#{product.shopify_variant_id}.json")
    variant  = response.body['variant']
    return unless variant

    compare_price = variant['compare_at_price'].to_f
    product.update_column(:compare_at_price, compare_price > 0 ? compare_price : nil)
    product.reload
  rescue StandardError => e
    Rails.logger.warn "Não foi possível buscar compare_at_price para #{product.sku}: #{e.message}"
  end

  # Se o produto tem compare_at_price > 0, usa ele * 50%.
  # Caso contrário, usa price * 50%.
  def calculate_pdv_price(product)
    return 0.0 unless product

    base = if product.respond_to?(:compare_at_price) && product.compare_at_price.to_f > 0
             product.compare_at_price.to_f
           else
             product.price.to_f
           end

    (base * 0.5).round(2)
  end

  def calculate_cart_total(cart_items)
    cart_items.sum { |item| item['price'].to_f * item['quantity'].to_i }
  end

  def determine_payment_method(payment_parcels)
    return 'dinheiro' unless payment_parcels.present?

    if payment_parcels.length == 1
      payment_parcels.first[:payment_method].presence || 'dinheiro'
    else
      'parcels'
    end
  end
end
