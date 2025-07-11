class PosController < ApplicationController
  before_action :authenticate_user!

  def index
    @cart_items = session[:cart_items] || []
    @total = calculate_total(@cart_items)
  end

  def search_product
    query = params[:query]

    if query.present?
      products = Product.where("sku LIKE ? OR shopify_product_name LIKE ?", "%#{query}%", "%#{query}%"
      ).limit(10)
      
      products_data = []

      begin
        # Usar token padrão para busca de produtos (Lagoa Seca)
        session = create_shopify_session(ENV['LAGOA_SECA_TOKEN_APP'])
        
        products.each do |product|
          stock_info = get_product_stock(product, session)
          products_data << {
            id: product.id,
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
      rescue => e
        Rails.logger.error "Erro ao buscar estoque: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        
        products_data = products.map do |product|
          {
            id: product.id,
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

      render json: { 
        success: true, 
        products: products_data 
      }
    else
      render json: { 
        success: false, 
        message: 'Query não fornecida' 
      }
    end
  end

  def check_stock
    product_id = params[:product_id]
    quantity = params[:quantity].to_i
    store_type = params[:store_type] || 'lagoa_seca'
    
    product = Product.find_by(id: product_id)

    if product.nil?
      render json: { 
        success: false, 
        message: 'Produto não encontrado' 
      }
      return
    end

    begin
      # Usar token baseado na loja selecionada
      access_token = get_access_token_for_store(store_type)
      session = create_shopify_session(access_token)
      stock_info = get_product_stock(product, session)
      available_quantity = stock_info[:quantity]

      if available_quantity >= quantity
        render json: { 
          success: true, 
          has_sufficient_stock: true,
          available_quantity: available_quantity,
          message: 'Estoque disponível' 
        }
      else
        render json: { 
          success: true, 
          has_sufficient_stock: false,
          available_quantity: available_quantity,
          message: "Estoque insuficiente. Disponível: #{available_quantity}" 
        }
      end
    rescue => e
      Rails.logger.error "Erro ao verificar estoque: #{e.message}"
      render json: { 
        success: false, 
        message: 'Erro ao verificar estoque no Shopify' 
      }
    end
  end

  def add_to_cart
    product_id = params[:product_id]
    quantity = params[:quantity].to_i
    store_type = params[:store_type] || 'lagoa_seca'
    
    product = Product.find_by(id: product_id)

    if product.nil?
      render json: { 
        success: false, 
        message: 'Produto não encontrado' 
      }
      return
    end

    session[:cart_items] ||= []

    existing_item = session[:cart_items].find { |item| item['product_id'] == product_id.to_s }

    if existing_item
      existing_item['quantity'] = existing_item['quantity'].to_i + quantity
    else
      session[:cart_items] << {
        'product_id' => product_id.to_s,
        'sku' => product.sku,
        'name' => product.shopify_product_name,
        'price' => product.price.to_f,
        'quantity' => quantity,
        'option1' => product.option1,
        'image_url' => product.image_url,
        'store_type' => store_type
      }
    end

    cart_count = session[:cart_items].sum { |item| item['quantity'].to_i }
    total = calculate_total(session[:cart_items])

    render json: { 
      success: true, 
      message: 'Produto adicionado ao carrinho',
      cart_count: cart_count,
      total: total
    }
  end

  def remove_from_cart
    product_id = params[:product_id]
    cart_items = session[:cart_items] || []

    cart_items.reject! { |item| item['product_id'] == product_id }
    session[:cart_items] = cart_items

    render json: { 
      success: true, 
      message: 'Item removido do carrinho' 
    }
  end

  def clear_cart
    session[:cart_items] = []

    render json: { 
      success: true, 
      message: 'Carrinho limpo' 
    }
  end

  def create_order
    cart_items = session[:cart_items] || []

    if cart_items.empty?
      render json: { 
        success: false, 
        message: 'Carrinho vazio' 
      }
      return
    end

    begin
      subtotal = calculate_total(cart_items)
      discount_amount = params[:discount_amount].to_f
      total_price = subtotal - discount_amount

      # Juntar endereço no backend
      address1 = build_address1(params)
      address2 = build_address2(params)

      order_pdv = OrderPdv.create!(
        user: current_user,
        customer_name: params[:customer_name],
        customer_email: params[:customer_email],
        customer_phone: params[:customer_phone],
        customer_cpf: params[:customer_cpf],
        address1: address1,
        address2: address2,
        city: params[:city],
        state: params[:state],
        zip: params[:zip],
        store_type: params[:store_type],
        payment_method: params[:payment_method],
        subtotal: subtotal,
        discount_amount: discount_amount,
        discount_reason: params[:discount_reason],
        total_price: total_price,
        notes: params[:notes],
        order_note: build_order_note(params),
        status: 'pending',
        reservation_status: 'none'
      )

      cart_items.each do |item|
        product = Product.find(item['product_id'])
        order_pdv.order_pdv_items.create!(
          product: product,
          sku: item['sku'],
          product_name: item['name'],
          price: item['price'],
          quantity: item['quantity'],
          total: item['price'].to_f * item['quantity'].to_i,
          option1: item['option1'],
          image_url: item['image_url']
        )
      end

      session[:cart_items] = []

      begin
        result = ShopifyIntegrationService.new(order_pdv).integrate
        
        if result[:success]
          # Atualizar status do pedido
          update_data = {
            status: 'integrated',
            shopify_order_id: result[:order_id],
            shopify_order_number: result[:order_number],
            integrated_at: Time.current,
            integration_error: nil
          }
          
          # Atualizar status da reserva se houver
          if result[:reservations]
            update_data[:reservation_status] = 'reserved'
            update_data[:inventory_reservations] = result[:reservations].to_json
            update_data[:reservation_error] = nil
          elsif result[:warning]
            update_data[:reservation_status] = 'reservation_error'
            update_data[:reservation_error] = result[:warning]
          end
          
          order_pdv.update!(update_data)
          
          success_message = "Pedido criado e integrado com sucesso ao Shopify (#{result[:location]})!"
          if result[:reservations]
            success_message += " Estoque reservado na location."
          elsif result[:warning]
            success_message += " ATENÇÃO: #{result[:warning]}"
          end
          
          render json: { 
            success: true, 
            message: success_message,
            order_id: order_pdv.id,
            shopify_order_number: result[:order_number],
            has_reservation: result[:reservations].present?
          }
        else
          order_pdv.update!(
            status: 'error',
            integration_error: result[:error],
            integration_attempts: 1,
            reservation_status: 'none'
          )
          
          render json: { 
            success: true, 
            message: 'Pedido registrado localmente. Erro na integração com Shopify, mas pode ser tentado novamente.',
            order_id: order_pdv.id,
            integration_error: result[:error]
          }
        end
      rescue => e
        order_pdv.update!(
          status: 'error',
          integration_error: e.message,
          integration_attempts: 1,
          reservation_status: 'none'
        )
        
        render json: { 
          success: true, 
          message: 'Pedido registrado localmente. Erro na integração com Shopify, mas pode ser tentado novamente.',
          order_id: order_pdv.id,
          integration_error: e.message
        }
      end

    rescue => e
      Rails.logger.error "Erro ao criar pedido local: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { 
        success: false, 
        message: "Erro interno: #{e.message}" 
      }
    end
  end

  private

  def calculate_total(cart_items)
    cart_items.sum { |item| item['price'].to_f * item['quantity'].to_i }
  end

  def build_address1(params)
    parts = []
    parts << params[:street] if params[:street].present?
    parts << params[:number] if params[:number].present?
    parts.join(', ')
  end

  def build_address2(params)
    parts = []
    parts << params[:complement] if params[:complement].present?
    parts << params[:neighborhood] if params[:neighborhood].present?
    parts.join(', ')
  end

  def get_access_token_for_store(store_type)
    case store_type
    when 'bh_shopping'
      ENV['BH_SHOPPING_TOKEN_APP']
    when 'rj'
      ENV['BARRA_SHOPPING_TOKEN_APP']
    when 'online'
      ENV['CHASE_ORDERS_TOKEN']
    else
      ENV['LAGOA_SECA_TOKEN_APP']
    end
  end

  def create_shopify_session(access_token)
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
    )
  end

  def get_product_stock(product, session)
    begin
      query = <<~GRAPHQL
        query {
          productVariant(id: "gid://shopify/ProductVariant/#{product.shopify_variant_id}") {
            id
            sku
            inventoryQuantity
          }
        }
      GRAPHQL

      client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
      response = client.query(query: query)
      variant = response.body.dig('data', 'productVariant')

      if variant.nil?
        return {
          quantity: 0,
          status: 'error',
          message: 'Variante não encontrada'
        }
      end

      quantity = variant['inventoryQuantity'] || 0

      if quantity > 10
        status = 'high'
        message = "Estoque: #{quantity} unidades"
      elsif quantity > 0
        status = 'low'
        message = "Estoque baixo: #{quantity} unidades"
      else
        status = 'out'
        message = 'Sem estoque (0 unidades)'
      end

      return {
        quantity: quantity,
        status: status,
        message: message
      }
    rescue => e
      Rails.logger.error "Erro ao buscar estoque do produto #{product.id}: #{e.message}"
      return {
        quantity: 0,
        status: 'error',
        message: 'Erro ao verificar estoque'
      }
    end
  end

  def build_order_note(params)
    notes = []
    notes << "=== VENDA PDV ==="
    notes << "Vendedor: #{current_user.name}"
    notes << "Loja: #{params[:store_type]}"
    notes << "Pagamento: #{params[:payment_method]}"
    notes << "Data: #{Time.current.strftime('%d/%m/%Y %H:%M')}"

    if params[:customer_cpf].present?
      notes << "CPF: #{params[:customer_cpf]}"
    end

    if params[:discount_amount].to_f > 0
      notes << "Desconto: R$ #{sprintf('%.2f', params[:discount_amount].to_f)}"
      notes << "Motivo: #{params[:discount_reason]}" if params[:discount_reason].present?
    end

    if params[:notes].present?
      notes << "Observações: #{params[:notes]}"
    end

    notes.join("\n")
  end
end
