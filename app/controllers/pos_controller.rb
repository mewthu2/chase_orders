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
        # DEBUG: Log dos valores do cupom
        Rails.logger.info "=== DEBUG CUPOM ==="
        Rails.logger.info "Código: #{discount.code}"
        Rails.logger.info "Tipo: #{discount.discount_type}"
        Rails.logger.info "Valor original: #{discount.discount_value}"
        Rails.logger.info "Valor como float: #{discount.discount_value.to_f}"
        Rails.logger.info "==================="

        # Log da busca do cupom
        LogService.log_discount_action(
          user: current_user,
          action: 'search_pdv',
          coupon_code: coupon_code,
          details: {
            found: true,
            search_term: coupon_code,
            discount_type: discount.discount_type,
            discount_value: discount.discount_value.to_f,
            timestamp: Time.current.iso8601,
            source: 'pdv'
          },
          request: request
        )

        # Verificar se o cupom é válido
        validation = validate_coupon_for_cart(discount, session[:cart_items] || [])
        
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
        # Log da busca sem resultado
        LogService.log_discount_action(
          user: current_user,
          action: 'search_pdv',
          coupon_code: coupon_code,
          details: {
            found: false,
            search_term: coupon_code,
            timestamp: Time.current.iso8601,
            source: 'pdv'
          },
          request: request
        )

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
    cart_items = session[:cart_items] || []

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

      # Validar cupom para o carrinho atual
      validation = validate_coupon_for_cart(discount, cart_items)
      
      unless validation[:valid]
        render json: { 
          success: false, 
          message: validation[:error]
        }
        return
      end

      # Calcular desconto
      subtotal = calculate_total(cart_items)
      discount_calculation = calculate_discount_amount(discount, subtotal, cart_items)
      
      # Salvar cupom na sessão
      session[:applied_coupon] = {
        code: coupon_code,
        discount_id: discount.id,
        discount_type: discount.discount_type,
        discount_value: discount.discount_value.to_f,
        discount_amount: discount_calculation[:discount_amount].to_f,
        applied_at: Time.current.iso8601
      }

      # Log da aplicação do cupom
      LogService.log_discount_action(
        user: current_user,
        action: 'apply_pdv',
        coupon_code: coupon_code,
        details: {
          subtotal: subtotal,
          discount_amount: discount_calculation[:discount_amount],
          discount_type: discount.discount_type,
          discount_value: discount.discount_value,
          timestamp: Time.current.iso8601,
          cart_items_count: cart_items.count
        },
        request: request
      )

      new_total = subtotal - discount_calculation[:discount_amount]

      render json: { 
        success: true, 
        message: 'Cupom aplicado com sucesso!',
        coupon: format_coupon_for_pdv(discount),
        discount_amount: discount_calculation[:discount_amount].to_f,
        new_total: new_total.to_f,
        subtotal: subtotal.to_f
      }
    rescue => e
      Rails.logger.error "Erro ao aplicar cupom: #{e.message}"
      render json: { 
        success: false, 
        message: 'Erro interno ao aplicar cupom'
      }
    end
  end

  def remove_coupon
    if session[:applied_coupon]
      coupon_code = session[:applied_coupon]['code']
      session.delete(:applied_coupon)
      
      # Log da remoção do cupom
      LogService.log_discount_action(
        user: current_user,
        action: 'remove_pdv',
        coupon_code: coupon_code,
        details: {
          timestamp: Time.current.iso8601,
          source: 'pdv'
        },
        request: request
      )

      cart_items = session[:cart_items] || []
      new_total = calculate_total(cart_items)

      render json: { 
        success: true, 
        message: 'Cupom removido',
        new_total: new_total
      }
    else
      render json: { 
        success: false, 
        message: 'Nenhum cupom aplicado'
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

    # Recalcular totais considerando cupom aplicado
    cart_count = session[:cart_items].sum { |item| item['quantity'].to_i }
    subtotal = calculate_total(session[:cart_items])
    
    response_data = {
      success: true, 
      message: 'Produto adicionado ao carrinho',
      cart_count: cart_count,
      subtotal: subtotal
    }

    # Se há cupom aplicado, recalcular desconto
    if session[:applied_coupon]
      discount_amount = session[:applied_coupon]['discount_amount'].to_f
      response_data[:total] = subtotal - discount_amount
      response_data[:discount_amount] = discount_amount
      response_data[:has_coupon] = true
    else
      response_data[:total] = subtotal
    end

    render json: response_data
  end

  def remove_from_cart
    product_id = params[:product_id]
    cart_items = session[:cart_items] || []

    cart_items.reject! { |item| item['product_id'] == product_id }
    session[:cart_items] = cart_items

    # Se carrinho ficou vazio, remover cupom
    if cart_items.empty? && session[:applied_coupon]
      session.delete(:applied_coupon)
    end

    render json: { 
      success: true, 
      message: 'Item removido do carrinho' 
    }
  end

  def clear_cart
    session[:cart_items] = []
    session.delete(:applied_coupon)

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
      
      # Calcular desconto (cupom + desconto manual)
      coupon_discount = 0
      coupon_code = nil
      coupon_details = nil
      
      if session[:applied_coupon]
        coupon_discount = session[:applied_coupon]['discount_amount'].to_f
        coupon_code = session[:applied_coupon]['code']
        coupon_details = session[:applied_coupon]
      end
      
      manual_discount = params[:discount_amount].to_f
      total_discount = coupon_discount + manual_discount
      total_price = subtotal - total_discount

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
        discount_amount: total_discount,
        discount_reason: build_discount_reason(coupon_code, params[:discount_reason]),
        coupon_code: coupon_code,
        coupon_discount_amount: coupon_discount,
        total_price: total_price,
        notes: params[:notes],
        order_note: build_order_note(params, coupon_details),
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

      # Limpar sessão
      session[:cart_items] = []
      session.delete(:applied_coupon)

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

          # Log do uso do cupom se aplicado
          if coupon_code
            LogService.log_discount_action(
              user: current_user,
              action: 'use_pdv',
              coupon_code: coupon_code,
              details: {
                order_id: order_pdv.id,
                shopify_order_id: result[:order_id],
                discount_amount: coupon_discount,
                subtotal: subtotal,
                timestamp: Time.current.iso8601
              },
              request: request
            )
          end
          
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
            has_reservation: result[:reservations].present?,
            coupon_used: coupon_code
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

  def find_discount_by_code(code)
    discount = Discount.find_by_code(code)
    return nil unless discount
    
    # Atualizar status baseado nas datas
    discount.update_status_from_dates! if discount.ends_at.present?
    
    # Retornar apenas se estiver ativo
    discount.is_active? ? discount : nil
  end

  def validate_coupon_for_cart(discount, cart_items)
    # Verificar se está ativo
    unless discount.is_active?
      return { valid: false, error: 'Cupom inativo ou expirado' }
    end

    # Verificar se não expirou
    if discount.is_expired?
      return { valid: false, error: 'Cupom expirado' }
    end

    # Verificar valor mínimo
    if discount.min_purchase_amount.present? && discount.min_purchase_amount > 0
      subtotal = calculate_total(cart_items)
      if subtotal < discount.min_purchase_amount
        return { 
          valid: false, 
          error: "Valor mínimo de R$ #{sprintf('%.2f', discount.min_purchase_amount)} não atingido" 
        }
      end
    end

    # Verificar quantidade mínima
    if discount.min_quantity.present? && discount.min_quantity > 0
      total_quantity = cart_items.sum { |item| item['quantity'].to_i }
      if total_quantity < discount.min_quantity
        return { 
          valid: false, 
          error: "Quantidade mínima de #{discount.min_quantity} itens não atingida" 
        }
      end
    end

    # Verificar limite de uso
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

    # Não pode ser maior que o subtotal
    discount_amount = [discount_amount, subtotal].min

    {
      discount_amount: discount_amount,
      percentage: discount.discount_type == 'percentage' ? discount.discount_value : nil
    }
  end

  def format_coupon_for_pdv(discount)
    # Para porcentagem, converter de decimal para percentual (0.1 -> 10)
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

  def build_discount_reason(coupon_code, manual_reason)
    reasons = []
    reasons << "Cupom: #{coupon_code}" if coupon_code.present?
    reasons << manual_reason if manual_reason.present?
    reasons.join(' | ')
  end

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

  def build_order_note(params, coupon_details = nil)
    notes = []
    notes << "=== VENDA PDV ==="
    notes << "Vendedor: #{current_user.name}"
    notes << "Loja: #{params[:store_type]}"
    notes << "Pagamento: #{params[:payment_method]}"
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
