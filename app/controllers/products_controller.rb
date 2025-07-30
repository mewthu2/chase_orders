class ProductsController < ApplicationController
  def index
    @products = filter_products
    @motors = Motor.where(job_name: 'Atualização de produtos').order(id: :desc).limit(1)
    @job_running = check_if_job_running
  end

  def inventory
    @current_page = params[:page]&.to_i || 1
    @per_page = 20
    @selected_location = params[:location] || get_default_location_for_user
    @search_term = params[:search_term] || ''
    
    # Verificar se o usuário tem acesso à location selecionada
    unless current_user.can_access_location?(@selected_location)
      @selected_location = get_default_location_for_user
    end
  
    # Base query - produtos com SKU válido E shopify_inventory_item_id
    products_query = Product.where.not(sku: [nil, ''])
                          .where.not(shopify_inventory_item_id: [nil, ''])
  
    # Aplicar filtro de busca se houver
    if @search_term.present?
      products_query = products_query.search(@search_term)
    end
  
    # Paginação
    @total_products = products_query.count
    @total_pages = (@total_products.to_f / @per_page).ceil
  
    offset = (@current_page - 1) * @per_page
    @products = products_query.limit(@per_page).offset(offset).order(:sku)
  
    # Buscar estoque em tempo real da Shopify para os produtos da página atual
    fetch_shopify_stock_for_products(@products, @selected_location)
  
    # Estatísticas por location
    calculate_statistics
  
    respond_to do |format|
      format.html
      format.json { render json: inventory_json_response }
    end
  end
  
  def search_inventory
    # Verificar se o usuário tem acesso à location
    location = params[:location]
    unless current_user.can_access_location?(location)
      location = get_default_location_for_user
    end
    
    redirect_to inventory_products_path(
      location: location,
      search_term: params[:search_term],
      page: 1
    )
  end

  def run_product_update
    SyncProductsSituationJob.perform_later
    flash[:notice] = 'Atualização de produtos iniciada com sucesso!'
    redirect_to products_path
  end

  private
  
  def get_default_location_for_user
    available_locations = current_user.available_locations_for_user
    available_locations.any? ? available_locations.first.last : 'lagoa_seca'
  end

  def fetch_shopify_stock_for_products(products, location)
    return if products.empty?

    Rails.logger.info "Fetching real-time stock for #{products.count} products in location: #{location}"

    begin
      # Converter location para o formato esperado pelo StockService
      store_type = convert_location_to_store_type(location)
    
      # Buscar estoque em tempo real apenas para produtos com shopify_inventory_item_id
      products.each do |product|
        if product.shopify_inventory_item_id.present?
          # Usar o StockService para buscar estoque em tempo real
          stock_result = StockService.check_stock(product.shopify_variant_id, 1, store_type)
        
          if stock_result[:success]
            real_stock = stock_result[:available_quantity] || 0
            Rails.logger.info "Real-time stock for #{product.sku}: #{real_stock}"
          else
            Rails.logger.warn "Failed to get stock for #{product.sku}: #{stock_result[:message]}"
            real_stock = get_fallback_stock(product, location)
          end
        
          # Adicionar método singleton para o estoque real
          product.define_singleton_method(:real_stock) { real_stock }
          product.define_singleton_method(:stock_source) { stock_result[:success] ? 'real_time' : 'fallback' }
        else
          Rails.logger.warn "Product #{product.sku} missing shopify_inventory_item_id - skipping"
          # Não adicionar este produto aos resultados ou marcar como sem inventory_item_id
          fallback_stock = get_fallback_stock(product, location)
          product.define_singleton_method(:real_stock) { fallback_stock }
          product.define_singleton_method(:stock_source) { 'no_shopify_id' }
        end
      end

    rescue => e
      Rails.logger.error "Error fetching real-time stock: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    
      # Em caso de erro, usar estoque do banco como fallback
      products.each do |product|
        fallback_stock = get_fallback_stock(product, location)
        product.define_singleton_method(:real_stock) { fallback_stock }
        product.define_singleton_method(:stock_source) { 'fallback' }
      end
    end
  end

  def convert_location_to_store_type(location)
    case location
    when 'lagoa_seca'
      'lagoa_seca'
    when 'bh_shopping'
      'bh_shopping'
    when 'rj'
      'rj'
    when 'log'
      'log'
    else
      'lagoa_seca' # default
    end
  end

  def get_fallback_stock(product, location)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca&.to_i || 0
    when 'bh_shopping'
      product.stock_bh_shopping&.to_i || 0
    when 'rj'
      product.stock_rj&.to_i || 0
    when 'log'
      product.stock_log&.to_i || 0
    else
      0
    end
  end
  
  def inventory_json_response
    {
      products: @products.map do |product|
        {
          id: product.id,
          sku: product.sku,
          name: product.shopify_product_name || 'Nome não disponível',
          stock: product.respond_to?(:real_stock) ? product.real_stock : get_stock_for_location(product, @selected_location)
        }
      end,
      pagination: {
        current_page: @current_page,
        total_pages: @total_pages,
        total_products: @total_products,
        per_page: @per_page
      },
      stats: @stats
    }
  end
  
  def get_stock_for_location(product, location)
    # Se o produto tem estoque real da Shopify, usar esse
    return product.real_stock if product.respond_to?(:real_stock)
    
    # Caso contrário, usar o estoque do banco (fallback)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca
    when 'bh_shopping'
      product.stock_bh_shopping
    when 'rj'
      product.stock_rj
    when 'log'
      product.stock_log
    else
      0
    end
  end

  def filter_products
    products = Product.all

    if params[:search].present?
      search_term = "%#{params[:search]}%"
      products = products.where('sku ILIKE ? OR shopify_product_name ILIKE ? OR id::text LIKE ? OR shopify_product_id LIKE ?',
                                 search_term, search_term, search_term, search_term)
    end

    if params[:price_min].present?
      products = products.where('price::float >= ?', params[:price_min].to_f)
    end

    if params[:price_max].present?
      products = products.where('price::float <= ?', params[:price_max].to_f)
    end

    if params[:cost_min].present?
      products = products.where('cost::float >= ?', params[:cost_min].to_f)
    end

    if params[:cost_max].present?
      products = products.where('cost::float <= ?', params[:cost_max].to_f)
    end

    if params[:stock_rj].present?
      case params[:stock_rj]
      when 'in_stock'
        products = products.where('stock_rj::integer > 0')
      when 'out_of_stock'
        products = products.where('stock_rj::integer = 0 OR stock_rj IS NULL')
      when 'low_stock'
        products = products.where('stock_rj::integer > 0 AND stock_rj::integer <= 3')
      end
    end

    if params[:stock_bh].present?
      case params[:stock_bh]
      when 'in_stock'
        products = products.where('stock_bh_shopping::integer > 0')
      when 'out_of_stock'
        products = products.where('stock_bh_shopping::integer = 0 OR stock_bh_shopping IS NULL')
      when 'low_stock'
        products = products.where('stock_bh_shopping::integer > 0 AND stock_bh_shopping::integer <= 3')
      end
    end

    if params[:stock_ls].present?
      case params[:stock_ls]
      when 'in_stock'
        products = products.where('stock_lagoa_seca::integer > 0')
      when 'out_of_stock'
        products = products.where('stock_lagoa_seca::integer = 0 OR stock_lagoa_seca IS NULL')
      when 'low_stock'
        products = products.where('stock_lagoa_seca::integer > 0 AND stock_lagoa_seca::integer <= 3')
      end
    end

    if params[:platform].present?
      case params[:platform]
      when 'shopify'
        products = products.where.not(shopify_product_id: nil)
      when 'tiny_rj'
        products = products.where.not(tiny_rj_id: nil)
      when 'tiny_bh'
        products = products.where.not(tiny_bh_shopping_id: nil)
      when 'tiny_ls'
        products = products.where.not(tiny_lagoa_seca_product_id: nil)
      end
    end

    if params[:sort].present?
      direction = params[:direction] == 'desc' ? 'DESC' : 'ASC'
      case params[:sort]
      when 'id'
        products = products.order("id #{direction}")
      when 'sku'
        products = products.order("sku #{direction}")
      when 'name'
        products = products.order("shopify_product_name #{direction}")
      when 'cost'
        products = products.order("cost::float #{direction} NULLS LAST")
      when 'price'
        products = products.order("price::float #{direction} NULLS LAST")
      when 'updated_at'
        products = products.order("updated_at #{direction}")
      end
    else
      products = products.order(updated_at: :desc)
    end

    products
  end

  def check_if_job_running
    motor = Motor.where(job_name: 'Atualização de produtos').order(id: :desc).first
    return false unless motor
    
    motor.start_time.present? && (motor.end_time.blank? || motor.running_time.blank?)
  end

  def calculate_statistics
    # Para as estatísticas, usar o estoque real dos produtos carregados
    if @products.respond_to?(:first) && @products.first&.respond_to?(:real_stock)
      @stats = {
        total: @total_products,
        with_stock: @products.count { |p| p.real_stock > 0 },
        low_stock: @products.count { |p| p.real_stock > 0 && p.real_stock < 10 },
        no_stock: @products.count { |p| p.real_stock == 0 }
      }
    else
      # Fallback para estatísticas do banco
      stock_field = case @selected_location
                   when 'lagoa_seca' then 'stock_lagoa_seca'
                   when 'bh_shopping' then 'stock_bh_shopping'
                   when 'rj' then 'stock_rj'
                   when 'log' then 'stock_log'
                   else 'stock_lagoa_seca'
                   end
      
      base_query = if @search_term.present?
                     Product.where.not(sku: [nil, '']).search(@search_term)
                   else
                     Product.where.not(sku: [nil, ''])
                   end
      
      @stats = {
        total: @total_products,
        with_stock: base_query.where("#{stock_field} > 0").count,
        low_stock: base_query.where("#{stock_field} > 0 AND #{stock_field} < 10").count,
        no_stock: base_query.where("#{stock_field} IS NULL OR #{stock_field} = 0").count
      }
    end
  end
end
