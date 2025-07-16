class PosController < ApplicationController
  before_action :authenticate_user!
  before_action :initialize_cart_service
  before_action :extend_cart_ttl, only: [:index, :get_cart_data]
  before_action :migrate_session_data, only: [:index]

  def index
    cart_summary = @cart_service.get_cart_summary
    @cart_items = cart_summary[:cart_items]
    @total = cart_summary[:total]
  end

  def get_cart_data
    cart_summary = @cart_service.get_cart_summary
    debug_info = @cart_service.debug_info
    
    render json: {
      success: true,
      cart_items: cart_summary[:cart_items],
      unique_count: cart_summary[:unique_count],
      total_items: cart_summary[:total_items],
      subtotal: cart_summary[:subtotal],
      discount_amount: cart_summary[:discount_amount],
      total: cart_summary[:total],
      applied_coupon: cart_summary[:applied_coupon],
      session_id: session.id.to_s,
      debug_info: debug_info
    }
  end

  def search_product
    query = params[:query]

    if query.present?
      products = Product.where("sku LIKE ? OR shopify_product_name LIKE ?", "%#{query}%", "%#{query}%").limit(10)
      
      products_data = []

      begin
        session_obj = create_shopify_session(ENV['LAGOA_SECA_TOKEN_APP'])
        
        products.each do |product|
          stock_info = get_product_stock(product, session_obj)
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

    # Preparar dados do produto
    product_data = {
      sku: product.sku,
      name: product.shopify_product_name,
      price: product.price.to_f,
      option1: product.option1,
      image_url: product.image_url,
      store_type: store_type
    }

    # Adicionar ao carrinho usando Redis
    result = @cart_service.add_item(product_id, product_data, quantity)
    
    if result[:success]
      cart_summary = @cart_service.get_cart_summary
      
      response_data = {
        success: true,
        message: 'Produto adicionado ao carrinho',
        cart_count: cart_summary[:total_items],
        subtotal: cart_summary[:subtotal],
        total: cart_summary[:total],
        cart_items: cart_summary[:cart_items],
        unique_count: cart_summary[:unique_count],
        session_id: session.id.to_s
      }

      # Adicionar informações do cupom se aplicado
      if cart_summary[:applied_coupon]
        response_data[:discount_amount] = cart_summary[:discount_amount]
        response_data[:has_coupon] = true
      end

      render json: response_data
    else
      render json: { 
        success: false, 
        message: result[:error] || 'Erro ao adicionar produto'
      }
    end
  rescue => e
    Rails.logger.error "Error in add_to_cart: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { 
      success: false, 
      message: "Erro interno: #{e.message}" 
    }
  end

  def update_cart_quantity
    product_id = params[:product_id]
    new_quantity = params[:quantity].to_i
    
    result = @cart_service.update_item_quantity(product_id, new_quantity)
    
    if result[:success]
      cart_summary = @cart_service.get_cart_summary
      
      response_data = {
        success: true,
        message: 'Quantidade atualizada',
        cart_count: cart_summary[:total_items],
        subtotal: cart_summary[:subtotal],
        total: cart_summary[:total],
        item_total: result[:item_total]
      }

      if cart_summary[:applied_coupon]
        response_data[:discount_amount] = cart_summary[:discount_amount]
        response_data[:has_coupon] = true
      end

      render json: response_data
    else
      render json: { 
        success: false, 
        message: result[:error] || 'Erro ao atualizar quantidade'
      }
    end
  end

  def remove_from_cart
    product_id = params[:product_id]

    result = @cart_service.remove_item(product_id)
    
    if result[:success]
      render json: { 
        success: true, 
        message: 'Item removido do carrinho',
        cart_items: result[:cart_items],
        unique_count: result[:unique_count],
        total_items: result[:total_items]
      }
    else
      render json: { 
        success: false, 
        message: result[:error] || 'Erro ao remover item'
      }
    end
  end

  def clear_cart
    result = @cart_service.clear_cart
    
    if result[:success]
      render json: { 
        success: true, 
        message: 'Carrinho limpo' 
      }
    else
      render json: { 
        success: false, 
        message: result[:error] || 'Erro ao limpar carrinho'
      }
    end
  end

  def create_order
    cart_summary = @cart_service.get_cart_summary
    cart_items = cart_summary[:cart_items]

    if cart_items.empty?
      render json: { 
        success: false, 
        message: 'Carrinho vazio' 
      }
      return
    end

    begin
      subtotal = cart_summary[:subtotal]
      manual_discount = params[:discount_amount].to_f
      coupon_discount = cart_summary[:discount_amount]
      coupon_code = cart_summary[:applied_coupon]&.dig('code')
      integrate_shopify = params[:integrate_shopify] == true || params[:integrate_shopify] == 'true'

      total_discount = manual_discount + coupon_discount
      total_price = subtotal - total_discount

      # Criar pedido
      order_pdv = OrderPdv.create!(
        user: current_user,
        customer_name: params[:customer_name],
        customer_email: params[:customer_email],
        customer_phone: params[:customer_phone],
        customer_cpf: params[:customer_cpf],
        address1: build_address1(params),
        address2: build_address2(params),
        city: params[:city],
        state: params[:state],
        zip: params[:zip],
        store_type: params[:store_type],
        payment_method: params[:payment_method],
        subtotal: subtotal,
        discount_amount: manual_discount,
        coupon_code: coupon_code,
        coupon_discount_amount: coupon_discount,
        total_price: total_price,
        notes: params[:notes],
        order_note: build_order_note(params, cart_summary[:applied_coupon]),
        status: 'pending',
        multi_payments: params[:multi_payments]&.to_json
      )

      # Criar itens do pedido
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

      # Limpar carrinho
      @cart_service.clear_cart

      # Verificar se deve integrar com Shopify
      if integrate_shopify
        # Tentar integrar com Shopify
        begin
          result = ShopifyIntegrationService.new(order_pdv).integrate
          
          if result[:success]
            order_pdv.update!(
              status: 'integrated',
              shopify_order_id: result[:order_id],
              shopify_order_number: result[:order_number],
              integrated_at: Time.current,
              integration_error: nil
            )
            
            render json: { 
              success: true, 
              message: 'Pedido criado e integrado com sucesso ao Shopify!',
              order_id: order_pdv.id,
              shopify_order_number: result[:order_number],
              coupon_used: coupon_code,
              integrated: true
            }
          else
            order_pdv.update!(
              status: 'error',
              integration_error: result[:error],
              integration_attempts: 1
            )
            
            render json: { 
              success: true, 
              message: 'Pedido registrado localmente. Erro na integração com Shopify.',
              order_id: order_pdv.id,
              integration_error: result[:error],
              coupon_used: coupon_code,
              integrated: false
            }
          end
        rescue => e
          order_pdv.update!(
            status: 'error',
            integration_error: e.message,
            integration_attempts: 1
          )
          
          render json: { 
            success: true, 
            message: 'Pedido registrado localmente. Erro na integração com Shopify.',
            order_id: order_pdv.id,
            integration_error: e.message,
            coupon_used: coupon_code,
            integrated: false
          }
        end
      else
        # Apenas salvar localmente sem integrar
        render json: { 
          success: true, 
          message: 'Pedido salvo localmente com sucesso! Poderá ser integrado posteriormente.',
          order_id: order_pdv.id,
          coupon_used: coupon_code,
          integrated: false
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

  def search_coupon
    coupon_code = params[:coupon_code]&.strip

    if coupon_code.blank?
      render json: { 
        success: false, 
        message: 'Código do cupom não fornecido' 
      }
      return
    end

    begin
      discount = find_discount_by_code(coupon_code)
      
      if discount
        cart_items = @cart_service.get_cart_items
        validation = validate_coupon_for_cart(discount, cart_items)
        
        if validation[:valid]
          render json: { 
            success: true, 
            coupon: format_coupon_for_pdv(discount),
            message: 'Cupom válido!'
          }
        else
          render json: { 
            success: false, 
            message: validation[:error],
            coupon_found: true
          }
        end
      else
        render json: { 
          success: false, 
          message: 'Cupom não encontrado ou inválido'
        }
      end
    rescue => e
      Rails.logger.error "Erro ao buscar cupom: #{e.message}"
      render json: { 
        success: false, 
        message: 'Erro interno ao buscar cupom'
      }
    end
  end

  def apply_coupon
    coupon_code = params[:coupon_code]&.strip
    cart_items = @cart_service.get_cart_items

    if coupon_code.blank?
      render json: { 
        success: false, 
        message: 'Código do cupom não fornecido' 
      }
      return
    end

    if cart_items.empty?
      render json: { 
        success: false, 
        message: 'Carrinho vazio' 
      }
      return
    end

    begin
      discount = find_discount_by_code(coupon_code)
      
      unless discount
        render json: { 
          success: false, 
          message: 'Cupom não encontrado' 
        }
        return
      end

      validation = validate_coupon_for_cart(discount, cart_items)
      
      unless validation[:valid]
        render json: { 
          success: false, 
          message: validation[:error]
        }
        return
      end

      subtotal = @cart_service.calculate_total(cart_items)
      discount_calculation = calculate_discount_amount(discount, subtotal, cart_items)
      
      coupon_data = {
        code: coupon_code,
        discount_id: discount.id,
        discount_type: discount.discount_type,
        discount_value: discount.discount_value.to_f,
        discount_amount: discount_calculation[:discount_amount].to_f,
        applied_at: Time.current.iso8601
      }
      
      result = @cart_service.apply_coupon(coupon_data)
      
      if result[:success]
        new_total = subtotal - discount_calculation[:discount_amount]

        render json: { 
          success: true, 
          message: 'Cupom aplicado com sucesso!',
          coupon: format_coupon_for_pdv(discount),
          discount_amount: discount_calculation[:discount_amount].to_f,
          new_total: new_total.to_f,
          subtotal: subtotal.to_f
        }
      else
        render json: { 
          success: false, 
          message: result[:error] || 'Erro ao aplicar cupom'
        }
      end
    rescue => e
      Rails.logger.error "Erro ao aplicar cupom: #{e.message}"
      render json: { 
        success: false, 
        message: 'Erro interno ao aplicar cupom'
      }
    end
  end

  def remove_coupon
    result = @cart_service.remove_coupon
    
    if result[:success]
      cart_summary = @cart_service.get_cart_summary

      render json: { 
        success: true, 
        message: 'Cupom removido',
        new_total: cart_summary[:total]
      }
    else
      render json: { 
        success: false, 
        message: result[:error] || 'Erro ao remover cupom'
      }
    end
  end

  private

  def initialize_cart_service
    @cart_service = CartService.new(session.id)
  end

  def extend_cart_ttl
    @cart_service.extend_ttl
  end

  def migrate_session_data
    # Migrar dados da sessão para Redis se existirem
    session_cart = session[:cart_items]
    session_coupon = session[:applied_coupon]
    
    if session_cart.present? || session_coupon.present?
      Rails.logger.info "Migrando dados da sessão para Redis"
      @cart_service.migrate_from_session(session_cart, session_coupon)
      
      # Limpar dados da sessão após migração
      session.delete(:cart_items)
      session.delete(:applied_coupon)
    end
  end

  def find_discount_by_code(code)
    discount = Discount.find_by_code(code)
    return nil unless discount
    
    discount.update_status_from_dates! if discount.ends_at.present?
    discount.is_active? ? discount : nil
  end

  def validate_coupon_for_cart(discount, cart_items)
    unless discount.is_active?
      return { valid: false, error: 'Cupom inativo ou expirado' }
    end

    if discount.is_expired?
      return { valid: false, error: 'Cupom expirado' }
    end

    if discount.min_purchase_amount.present? && discount.min_purchase_amount > 0
      subtotal = @cart_service.calculate_total(cart_items)
      if subtotal < discount.min_purchase_amount
        return { 
          valid: false, 
          error: "Valor mínimo de R$ #{sprintf('%.2f', discount.min_purchase_amount)} não atingido" 
        }
      end
    end

    if discount.min_quantity.present? && discount.min_quantity > 0
      total_quantity = cart_items.sum { |item| item['quantity'].to_i }
      if total_quantity < discount.min_quantity
        return { 
          valid: false, 
          error: "Quantidade mínima de #{discount.min_quantity} itens não atingida" 
        }
      end
    end

    if discount.usage_limit.present? && discount.usage_limit > 0
      if discount.usage_count >= discount.usage_limit
        return { valid: false, error: 'Cupom esgotado (limite de uso atingido)' }
      end
    end

    { valid: true }
  end

  def calculate_discount_amount(discount, subtotal, cart_items)
    case discount.discount_type
    when 'percentage'
      discount_amount = subtotal * (discount.discount_value / 100.0)
    when 'fixed_amount'
      discount_amount = discount.discount_value
    else
      discount_amount = 0
    end

    discount_amount = [discount_amount, subtotal].min

    {
      discount_amount: discount_amount,
      percentage: discount.discount_type == 'percentage' ? discount.discount_value : nil
    }
  end

  def format_coupon_for_pdv(discount)
    display_value = if discount.discount_type == 'percentage'
      (discount.discount_value.to_f * 100).round(2)
    else
      discount.discount_value.to_f
    end

    {
      id: discount.id,
      code: discount.code,
      title: discount.title,
      discount_type: discount.discount_type,
      discount_value: display_value,
      min_purchase_amount: discount.min_purchase_amount&.to_f,
      min_quantity: discount.min_quantity,
      usage_count: discount.usage_count,
      usage_limit: discount.usage_limit,
      is_active: discount.is_active,
      expires_at: discount.ends_at&.strftime('%d/%m/%Y')
    }
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

  def create_shopify_session(access_token)
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
    )
  end

  def get_product_stock(product, session_obj)
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

      client = ShopifyAPI::Clients::Graphql::Admin.new(session: session_obj)
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

  def build_order_note(params, coupon_details = nil)
    notes = []
    notes << "=== VENDA PDV ==="
    notes << "Vendedor: #{current_user.name}"
    notes << "Loja: #{params[:store_type]}"
    notes << "Pagamento: #{params[:payment_method]}"
    
    if params[:payment_method] == 'multi' && params[:multi_payments].present?
      notes << "=== PARCELAS ==="
      params[:multi_payments].each_with_index do |payment, index|
        notes << "Parcela #{index + 1}: #{payment[:method]} - R$ #{sprintf('%.2f', payment[:amount].to_f)} - #{payment[:date]}"
      end
    end
    
    notes << "Data: #{Time.current.strftime('%d/%m/%Y %H:%M')}"

    if params[:customer_cpf].present?
      notes << "CPF: #{params[:customer_cpf]}"
    end

    if coupon_details
      notes << "=== CUPOM APLICADO ==="
      notes << "Código: #{coupon_details['code']}"
      notes << "Desconto: R$ #{sprintf('%.2f', coupon_details['discount_amount'])}"
      notes << "Tipo: #{coupon_details['discount_type'] == 'percentage' ? 'Percentual' : 'Valor Fixo'}"
    end

    if params[:discount_amount].to_f > 0
      notes << "Desconto Manual: R$ #{sprintf('%.2f', params[:discount_amount].to_f)}"
      notes << "Motivo: #{params[:discount_reason]}" if params[:discount_reason].present?
    end

    if params[:notes].present?
      notes << "Observações: #{params[:notes]}"
    end

    notes.join("\n")
  end
end
