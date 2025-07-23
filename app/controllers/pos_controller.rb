class PosController < ApplicationController
  before_action :authenticate_user!
  
  def index
    @cart_items = session[:cart_items] || []
    @total = calculate_cart_total(@cart_items)
  end

  def search_product
    begin
      Rails.logger.info "PosController#search_product called with params: #{params.inspect}"
      
      query = params[:query]
      store_type = params[:store_type] || 'lagoa_seca'
      
      if query.blank?
        render json: { success: false, error: 'Query não pode estar vazio' }
        return
      end

      products = search_products_by_store(query, store_type)
      
      Rails.logger.info "Found #{products.count} products"
      
      # Get real-time stock for each product
      products_with_stock = products.map do |product|
        stock_result = StockService.check_stock(product.shopify_variant_id, 1, store_type)
        
        format_product_for_json(product, store_type, stock_result)
      end
      
      render json: { 
        success: true, 
        products: products_with_stock
      }
    rescue => e
      Rails.logger.error "Erro na busca de produtos: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { success: false, error: e.message }
    end
  end

  def add_to_cart
    begin
      product_id = params[:product_id]
      quantity = params[:quantity].to_i
      store_type = params[:store_type] || 'lagoa_seca'
      
      if quantity < 1
        render json: { success: false, error: 'Quantidade deve ser maior que zero' }
        return
      end

      product = Product.find_by(shopify_variant_id: product_id)
      unless product
        render json: { success: false, error: 'Produto não encontrado' }
        return
      end

      # Check real-time stock before adding to cart
      stock_result = StockService.check_stock(product_id, quantity, store_type)
      
      unless stock_result[:success] && stock_result[:has_sufficient_stock]
        render json: { 
          success: false, 
          error: stock_result[:message] || 'Estoque insuficiente'
        }
        return
      end

      session[:cart_items] ||= []
      
      # Check if product already exists in cart
      existing_item = session[:cart_items].find { |item| item['product_id'] == product_id }
      
      if existing_item
        new_quantity = existing_item['quantity'].to_i + quantity
        
        # Check stock for new total quantity
        stock_check = StockService.check_stock(product_id, new_quantity, store_type)
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
          'sku' => product.sku,
          'name' => product.shopify_product_name,
          'price' => product.price.to_f,
          'quantity' => quantity,
          'image_url' => get_product_image_url(product, store_type)
        }
      end

      total = calculate_cart_total(session[:cart_items])
      
      render json: { 
        success: true, 
        cart_items: session[:cart_items],
        total: total
      }
    rescue => e
      Rails.logger.error "Erro ao adicionar ao carrinho: #{e.message}"
      render json: { success: false, error: e.message }
    end
  end

  def update_cart_quantity
    begin
      product_id = params[:product_id]
      quantity = params[:quantity].to_i
      store_type = params[:store_type] || 'lagoa_seca'
      
      if quantity < 1
        render json: { success: false, error: 'Quantidade deve ser maior que zero' }
        return
      end

      session[:cart_items] ||= []
      
      item = session[:cart_items].find { |item| item['product_id'] == product_id }
      if item
        # Check real-time stock for new quantity
        stock_result = StockService.check_stock(product_id, quantity, store_type)
        
        unless stock_result[:success] && stock_result[:has_sufficient_stock]
          render json: { 
            success: false, 
            error: stock_result[:message] || 'Estoque insuficiente'
          }
          return
        end
        
        item['quantity'] = quantity
      else
        render json: { success: false, error: 'Item não encontrado no carrinho' }
        return
      end

      total = calculate_cart_total(session[:cart_items])
      
      render json: { 
        success: true, 
        cart_items: session[:cart_items],
        total: total
      }
    rescue => e
      Rails.logger.error "Erro ao atualizar quantidade: #{e.message}"
      render json: { success: false, error: e.message }
    end
  end

  def remove_from_cart
    begin
      product_id = params[:product_id]
      
      session[:cart_items] ||= []
      session[:cart_items].reject! { |item| item['product_id'] == product_id }

      total = calculate_cart_total(session[:cart_items])
      
      render json: { 
        success: true, 
        cart_items: session[:cart_items],
        total: total
      }
    rescue => e
      Rails.logger.error "Erro ao remover do carrinho: #{e.message}"
      render json: { success: false, error: e.message }
    end
  end

  def clear_cart
    begin
      session[:cart_items] = []
      
      render json: { 
        success: true, 
        cart_items: [],
        total: 0
      }
    rescue => e
      Rails.logger.error "Erro ao limpar carrinho: #{e.message}"
      render json: { success: false, error: e.message }
    end
  end

  def search_coupon
    begin
      coupon_code = params[:coupon_code]
      
      # Simulate coupon search - replace with actual coupon logic
      if coupon_code == 'DESCONTO10'
        render json: {
          success: true,
          coupon: {
            code: coupon_code,
            description: 'Desconto de R$ 10,00',
            discount_amount: 10.00
          }
        }
      else
        render json: {
          success: false,
          error: 'Cupom não encontrado ou inválido'
        }
      end
    rescue => e
      Rails.logger.error "Erro ao buscar cupom: #{e.message}"
      render json: { success: false, error: e.message }
    end
  end

  def create_order
    begin
      Rails.logger.info "Creating order with params: #{params.inspect}"
      
      cart_items = session[:cart_items] || []
      if cart_items.empty?
        render json: { success: false, error: 'Carrinho está vazio' }
        return
      end

      # Calculate totals
      subtotal = calculate_cart_total(cart_items)
      discount_amount = params[:discount_amount].to_f || 0
      total_price = subtotal - discount_amount

      # Create order
      order = OrderPdv.new(
        user: current_user,
        customer_name: params[:customer_name],
        customer_email: params[:customer_email],
        customer_phone: params[:customer_phone],
        customer_cpf: params[:customer_cpf],
        address1: "#{params[:street]}, #{params[:number]}",
        address2: params[:complement],
        city: params[:city],
        state: params[:state],
        zip: params[:zip],
        store_type: params[:store_type],
        payment_method: determine_payment_method(params[:payment_parcels]),
        subtotal: subtotal,
        discount_amount: discount_amount,
        discount_reason: params[:discount_reason],
        total_price: total_price,
        order_note: params[:notes],
        status: 'pending'
      )

      ActiveRecord::Base.transaction do
        order.save!

        # Create order items
        cart_items.each do |item|
          product = Product.find_by(shopify_variant_id: item['product_id'])
          next unless product

          OrderPdvItem.create!(
            order_pdv: order,
            product: product,
            sku: item['sku'],
            product_name: item['name'],
            quantity: item['quantity'],
            price: item['price'],
            total: item['price'].to_f * item['quantity'].to_i
          )
        end

        # Create payment parcels
        if params[:payment_parcels].present?
          params[:payment_parcels].each do |parcel_data|
            next if parcel_data[:payment_method].blank? || parcel_data[:amount].blank?
            
            OrderParcel.create!(
              order_pdv: order,
              payment_method: parcel_data[:payment_method],
              amount: parcel_data[:amount].to_f,
              notes: parcel_data[:notes],
              status: 'pending'
            )
          end
        end

        # Integrate with Shopify if requested
        if params[:integrate_shopify] == 'on'
          integration_service = ShopifyIntegrationService.new(order)
          integration_result = integration_service.integrate
          
          if integration_result[:success]
            order.update!(
              status: 'integrated',
              shopify_order_id: integration_result[:order_id],
              shopify_order_number: integration_result[:order_number],
              integrated_at: Time.current
            )
          else
            order.update!(
              status: 'error',
              integration_error: integration_result[:error]
            )
          end
        end
      end

      # Clear cart
      session[:cart_items] = []

      render json: {
        success: true,
        message: 'Pedido criado com sucesso!',
        order_id: order.id
      }
    rescue => e
      Rails.logger.error "Erro ao criar pedido: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { success: false, error: e.message }
    end
  end

  private

  def search_products_by_store(query, store_type)
    query_downcase = query.downcase
    
    Product.where(
      "sku LIKE ? OR shopify_product_name LIKE ?",
      "%#{query_downcase}%", "%#{query_downcase}%"
    ).limit(20)
  end

  def format_product_for_json(product, store_type, stock_result = nil)
    # Use real-time stock data if available
    if stock_result
      stock_quantity = stock_result[:available_quantity] || 0
      stock_status = if stock_quantity <= 0
                      'out'
                    elsif stock_quantity <= 5
                      'low'
                    else
                      'high'
                    end
      location = stock_result[:location] || get_location_name(store_type)
    else
      # Fallback to mock data if stock service fails
      stock_quantity = rand(0..50)
      stock_status = case stock_quantity
                     when 0 then 'out'
                     when 1..5 then 'low'
                     else 'high'
                     end
      location = get_location_name(store_type)
    end

    {
      id: product.shopify_variant_id,
      sku: product.sku,
      name: product.shopify_product_name,
      price: product.price.to_f,
      option1: product.option1,
      option2: product.option2,
      option3: product.option3,
      image_url: get_product_image_url(product, store_type),
      vendor: product.vendor,
      stock: stock_quantity,
      stock_status: stock_status,
      location: location
    }
  end

  def get_product_image_url(product, store_type)
    # Return placeholder or actual image URL
    if product.sku.present?
      sku_clean = product.sku.downcase.gsub(/[^a-z0-9]/, '-')
      "https://via.placeholder.com/300x300/cccccc/666666?text=#{product.sku}"
    else
      nil
    end
  end

  def get_location_name(store_type)
    case store_type
    when 'lagoa_seca' then 'Lagoa Seca'
    when 'bh_shopping' then 'BH Shopping'
    when 'rj' then 'Barra Shopping (RJ)'
    when 'online' then 'Online Store'
    else 'Loja Desconhecida'
    end
  end

  def calculate_cart_total(cart_items)
    cart_items.sum { |item| item['price'].to_f * item['quantity'].to_i }
  end

  def determine_payment_method(payment_parcels)
    return 'dinheiro' unless payment_parcels.present?
    
    if payment_parcels.length == 1
      payment_parcels.first[:payment_method]
    else
      'parcels'
    end
  end
end
