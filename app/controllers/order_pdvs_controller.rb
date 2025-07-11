class OrderPdvsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_order_pdv, only: [:show, :edit, :update, :integrate, :add_product, :remove_product]

  def index
    @order_pdvs = OrderPdv.includes(:user)
                          .by_status(params[:status])
                          .recent

    @order_pdvs = @order_pdvs.paginate(page: params[:page], per_page: params_per_page(params[:per_page]))
    
    @status_counts = {
      all: OrderPdv.count,
      pending: OrderPdv.pending.count,
      integrated: OrderPdv.integrated.count,
      error: OrderPdv.error.count
    }
  end

  def show
    @items = @order_pdv.order_pdv_items.includes(:product)
  end

  def edit
    @items = @order_pdv.order_pdv_items.includes(:product)
    # Separar endereço para edição
    @address_parts = parse_address(@order_pdv)
  end

  def update
    # Juntar endereço no backend
    address1 = build_address1(params[:order_pdv])
    address2 = build_address2(params[:order_pdv])
    
    order_params = order_pdv_params.merge(
      address1: address1,
      address2: address2
    )

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
    begin
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
          render json: { 
            success: true, 
            message: 'Pedido integrado com sucesso ao Shopify!',
            order_number: result[:order_number]
          }
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
          render json: { 
            success: false, 
            message: "Erro na integração: #{result[:error]}"
          }
        else
          redirect_to @order_pdv, alert: "Erro na integração: #{result[:error]}"
        end
      end
    rescue => e
      @order_pdv.update!(
        status: 'error',
        integration_error: e.message,
        integration_attempts: @order_pdv.integration_attempts + 1
      )
      
      if request.xhr? || request.format.json?
        render json: { 
          success: false, 
          message: "Erro na integração: #{e.message}"
        }
      else
        redirect_to @order_pdv, alert: "Erro na integração: #{e.message}"
      end
    end
  end

  def search_product
    query = params[:query]
    order_pdv_id = params[:order_pdv_id]

    if query.present?
      products = Product.where("sku LIKE ? OR shopify_product_name LIKE ?", "%#{query}%", "%#{query}%"
      ).limit(10)
      
      products_data = []

      begin
        session = create_shopify_session
        
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

  def add_product
    product_id = params[:product_id]
    quantity = params[:quantity].to_i
    
    product = Product.find_by(id: product_id)

    if product.nil?
      render json: { 
        success: false, 
        message: 'Produto não encontrado' 
      }
      return
    end

    existing_item = @order_pdv.order_pdv_items.find_by(product: product)

    if existing_item
      existing_item.update!(quantity: existing_item.quantity + quantity)
    else
      @order_pdv.order_pdv_items.create!(
        product: product,
        sku: product.sku,
        product_name: product.shopify_product_name,
        price: product.price,
        quantity: quantity,
        total: product.price * quantity,
        option1: product.option1,
        image_url: product.image_url
      )
    end

    recalculate_totals

    render json: { 
      success: true, 
      message: 'Produto adicionado ao pedido',
      total: @order_pdv.formatted_total
    }
  end

  def remove_product
    item_id = params[:item_id]
    item = @order_pdv.order_pdv_items.find_by(id: item_id)

    if item
      item.destroy
      recalculate_totals
      render json: { 
        success: true, 
        message: 'Item removido do pedido',
        total: @order_pdv.formatted_total
      }
    else
      render json: { 
        success: false, 
        message: 'Item não encontrado' 
      }
    end
  end

  private

  def set_order_pdv
    @order_pdv = OrderPdv.find(params[:id])
  end

  def order_pdv_params
    params.require(:order_pdv).permit(
      :customer_name, :customer_email, :customer_phone, :customer_cpf,
      :street, :number, :complement, :neighborhood, :city, :state, :zip, 
      :store_type, :payment_method, :discount_amount, :discount_reason, :notes
    )
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

  def parse_address(order_pdv)
    # Tentar separar o endereço existente para edição
    address1_parts = order_pdv.address1&.split(', ') || []
    address2_parts = order_pdv.address2&.split(', ') || []

    {
      street: address1_parts[0] || '',
      number: address1_parts[1] || '',
      complement: address2_parts[0] || '',
      neighborhood: address2_parts[1] || ''
    }
  end

  def params_per_page(per_page_param)
    per_page = per_page_param.to_i
    per_page > 0 ? per_page : 20
  end

  def recalculate_totals
    @order_pdv.order_pdv_items.each do |item|
      item.update_column(:total, item.price * item.quantity)
    end
    
    subtotal = @order_pdv.order_pdv_items.sum(:total)
    total_price = subtotal - (@order_pdv.discount_amount || 0)
    
    @order_pdv.update!(
      subtotal: subtotal,
      total_price: total_price
    )
  end

  def create_shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV['LAGOA_SECA_TOKEN_APP']
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
end
