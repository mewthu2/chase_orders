class StockCorrectionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_stock_correction, only: [:show, :edit, :update, :destroy, :finalize_correction, :execute_all, :save_item_correction, :reopen]
  before_action :check_edit_permission, only: [:edit, :update, :save_item_correction]

  def index
    # Paginação manual
    @per_page = 10
    @current_page = (params[:page] || 1).to_i
    offset = (@current_page - 1) * @per_page

    # Buscar correções baseado no perfil do usuário
    if current_user.admin?
      @stock_corrections = StockCorrection.includes(:stock_correction_items)
                                         .order(created_at: :desc)
                                         .limit(@per_page)
                                         .offset(offset)
      
      # Estatísticas para admin (todas as correções)
      @total_corrections = StockCorrection.count
      @pending_corrections = StockCorrection.where(status: [nil, 'pending']).count
      @completed_corrections = StockCorrection.where(status: 'executed').count
      @synced_corrections = StockCorrection.joins(:stock_correction_items)
                                          .where(stock_correction_items: { 
                                            last_shopify_sync_at: Date.current.beginning_of_day..Date.current.end_of_day 
                                          })
                                          .distinct.count
    else
      # Para usuários não-admin, filtrar por locations permitidas
      allowed_locations = current_user.allowed_location_keys
      @stock_corrections = StockCorrection.where(location: allowed_locations)
                                         .includes(:stock_correction_items)
                                         .order(created_at: :desc)
                                         .limit(@per_page)
                                         .offset(offset)
      
      # Estatísticas para usuário (apenas suas locations)
      base_corrections = StockCorrection.where(location: allowed_locations)
      @total_corrections = base_corrections.count
      @pending_corrections = base_corrections.where(status: [nil, 'pending']).count
      @completed_corrections = base_corrections.where(status: 'executed').count
      @synced_corrections = base_corrections.joins(:stock_correction_items)
                                           .where(stock_correction_items: { 
                                             last_shopify_sync_at: Date.current.beginning_of_day..Date.current.end_of_day 
                                           })
                                           .distinct.count
    end

    # Calcular total de páginas
    @total_pages = (@total_corrections.to_f / @per_page).ceil
  end

  def show
    # Paginação para o show
    @per_page = 20
    @current_page = (params[:page] || 1).to_i
    
    # Busca de produto específico
    if params[:search_term].present?
      @search_term = params[:search_term].strip
      @search_item = @stock_correction.stock_correction_items
                                     .joins(:product)
                                     .where(products: { sku: @search_term })
                                     .includes(:product)
                                     .first
    end
    
    # Itens processados com paginação - APENAS OS QUE TIVERAM CORREÇÃO
    @total_processed = @stock_correction.stock_correction_items.where(needs_correction: true).count
    @total_pages = (@total_processed.to_f / @per_page).ceil
    
    offset = (@current_page - 1) * @per_page
    @processed_items = @stock_correction.stock_correction_items
                                       .where(needs_correction: true)
                                       .includes(:product)
                                       .order(:created_at)
                                       .limit(@per_page)
                                       .offset(offset)

    # APENAS buscar estoque real da Shopify para o item pesquisado
    fetch_real_time_stock_for_items([@search_item].compact) if @search_item
  
    # Estatísticas
    @stats = {
      total: @stock_correction.stock_correction_items.count,
      corrections: @stock_correction.stock_correction_items.where(needs_correction: true).count,
      executed: @stock_correction.stock_correction_items.where(needs_correction: true, executed: true).count
    }
  end

  def new
    @stock_correction = StockCorrection.new
    @available_locations = current_user.available_locations_for_user
    
    # Definir location padrão
    @location = params[:location] || current_user.default_location
    
    # Verificar se o usuário tem acesso à location
    unless current_user.can_access_location?(@location)
      @location = current_user.default_location
    end
  end

  def create
    @stock_correction = StockCorrection.new(stock_correction_params)
    @stock_correction.status = 'pending'

    # Verificar se o usuário pode acessar a location especificada
    unless current_user.can_access_location?(@stock_correction.location)
      flash[:alert] = "Você não tem permissão para criar conferências na location '#{User.location_name(@stock_correction.location)}'"
      redirect_to stock_corrections_path and return
    end

    if @stock_correction.save
      # Criar items para todos os produtos da location após salvar
      create_correction_items(@stock_correction)
      redirect_to edit_stock_correction_path(@stock_correction), notice: 'Conferência criada com sucesso!'
    else
      @available_locations = current_user.available_locations_for_user
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @location = @stock_correction.location
    
    # Paginação para o edit
    @per_page = 20
    @current_page = (params[:page] || 1).to_i

    # Busca de produto específico - LÓGICA CORRIGIDA
    if params[:search_term].present?
      @search_term = params[:search_term].strip
      product = Product.find_by(sku: @search_term)
      
      if product
        # Verificar se já existe um item COM CORREÇÃO para este produto
        existing_item_with_correction = @stock_correction.stock_correction_items
                                                         .where(product: product, needs_correction: true)
                                                         .first
        
        if existing_item_with_correction
          # Se já tem correção, mostrar o item existente
          @search_item = existing_item_with_correction
        else
          # Se não tem correção, buscar ou criar o item
          existing_item = @stock_correction.stock_correction_items.find_by(product: product)
          
          if existing_item
            # Item existe mas sem correção, usar o existente
            @search_item = existing_item
          else
            # Item não existe, criar um novo
            current_stock = stock_for_location(product, @location)
            
            @search_item = @stock_correction.stock_correction_items.build(
              product: product,
              current_stock: current_stock,
              corrected_stock: current_stock,
              needs_correction: false,
              executed: false
            )
          end
          
          # Buscar estoque real da Shopify
          real_stock = fetch_shopify_stock(product, @location)
          @search_item.define_singleton_method(:real_stock) { real_stock || stock_for_location(product, @location) }
          @search_item.define_singleton_method(:stock_source) do
            if real_stock
              'shopify_real_time'
            elsif product.shopify_variant_id.present?
              'database_fallback'
            else
              'no_shopify_id'
            end
          end
        end
      else
        @search_error = "Produto não encontrado"
      end
    end

    # Paginação dos itens - APENAS OS QUE TIVERAM CORREÇÃO
    @total_processed = @stock_correction.stock_correction_items.where(needs_correction: true).count
    @total_pages = (@total_processed.to_f / @per_page).ceil
  
    offset = (@current_page - 1) * @per_page
    @processed_items = @stock_correction.stock_correction_items
                                       .where(needs_correction: true)
                                       .includes(:product)
                                       .order(:created_at)
                                       .limit(@per_page)
                                       .offset(offset)

    # APENAS buscar estoque real da Shopify para o item pesquisado
    fetch_real_time_stock_for_items([@search_item].compact) if @search_item
    
    # Estatísticas
    @stats = {
      total: @stock_correction.stock_correction_items.count,
      corrections: @stock_correction.stock_correction_items.where(needs_correction: true).count,
      executed: @stock_correction.stock_correction_items.where(needs_correction: true, executed: true).count
    }
  end

  def update
    # Bloquear mudança de location e data se não for admin
    if !current_user.admin? && (@stock_correction.location != stock_correction_params[:location] || @stock_correction.correction_date.to_s != stock_correction_params[:correction_date])
      redirect_to edit_stock_correction_path(@stock_correction), 
                  alert: 'Apenas administradores podem alterar location e data da conferência.'
      return
    end

    if @stock_correction.update(stock_correction_params)
      redirect_to edit_stock_correction_path(@stock_correction), 
                  notice: 'Conferência atualizada com sucesso!'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stock_correction.destroy
    redirect_to stock_corrections_path, notice: 'Conferência removida com sucesso!'
  end

  def finalize_correction
    begin
      ActiveRecord::Base.transaction do
        # Executar todas as correções pendentes primeiro
        pending_items = @stock_correction.stock_correction_items.where(needs_correction: true, executed: false)
        executed_count = 0
        
        pending_items.each do |item|
          if item.update(executed: true, executed_at: Time.current)
            executed_count += 1
          end
        end
        
        # Atualizar status da conferência
        @stock_correction.update!(status: 'executed', executed_at: Time.current)
        
        # Mensagem de sucesso
        redirect_to stock_corrections_path, 
                    notice: "Conferência finalizada com sucesso! #{executed_count} correções executadas. A integração será feita em tempo real."
      end
    rescue => e
      Rails.logger.error "Erro ao finalizar conferência: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      redirect_to edit_stock_correction_path(@stock_correction), 
                  alert: "Erro ao finalizar conferência: #{e.message}"
    end
  end

  def reopen
    # Apenas admins podem reabrir conferências
    unless current_user.admin?
      redirect_to stock_corrections_path, alert: 'Apenas administradores podem reabrir conferências.'
      return
    end

    if @stock_correction.update(status: 'pending', executed_at: nil)
      redirect_to stock_corrections_path, notice: 'Conferência reaberta com sucesso!'
    else
      redirect_to stock_corrections_path, alert: 'Erro ao reabrir conferência.'
    end
  end

  def execute_all
    executed_count = 0
    
    @stock_correction.stock_correction_items.where(executed: false).each do |item|
      if item.update(executed: true, executed_at: Time.current)
        executed_count += 1
      end
    end
    
    redirect_to edit_stock_correction_path(@stock_correction), 
                notice: "#{executed_count} correções executadas com sucesso!"
  end

  def save_item_correction
    product_id = params[:product_id]
    corrected_stock = params[:corrected_stock].to_i
    correction_reason = params[:correction_reason]

    # Buscar ou criar o item da conferência
    item = @stock_correction.stock_correction_items.find_or_initialize_by(product_id: product_id)
    
    if item.new_record?
      # Se é um novo item, definir o estoque atual
      product = Product.find(product_id)
      current_stock = stock_for_location(product, @stock_correction.location)
      item.current_stock = current_stock
    end

    # Salvar o estoque anterior antes da correção
    if item.stock_before.blank?
      item.stock_before = item.current_stock || 0
    end

    # Atualizar com a correção
    item.assign_attributes(
      corrected_stock: corrected_stock,
      correction_reason: correction_reason,
      needs_correction: true,
      executed: false  # Deixar como false para o execute_correction! processar
    )

    if item.save
      # Executar a correção (que agora inclui integração automática)
      Rails.logger.info "=== Executing correction with automatic Shopify integration ==="
      
      if item.execute_correction!
        render json: { 
          success: true, 
          message: 'Correção salva e integrada com sucesso!',
          shopify_status: item.shopify_sync_status
        }
      else
        render json: { 
          success: false, 
          message: 'Erro ao executar a correção. Verifique os logs.' 
        }
      end
    else
      render json: { success: false, message: item.errors.full_messages.join(', ') }
    end
  rescue => e
    Rails.logger.error "Erro ao salvar correção: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, message: e.message }
  end

  private

  def set_stock_correction
    if current_user.admin?
      @stock_correction = StockCorrection.find(params[:id])
    else
      # Usuários não-admin só podem acessar correções de suas locations
      allowed_locations = current_user.allowed_location_keys
      @stock_correction = StockCorrection.where(location: allowed_locations).find(params[:id])
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to stock_corrections_path, alert: 'Conferência não encontrada ou sem permissão de acesso.'
  end

  def check_edit_permission
    if @stock_correction.status == 'executed' && !current_user.admin?
      redirect_to @stock_correction, 
                  alert: 'Apenas administradores podem editar conferências finalizadas.'
    end
  end

  def stock_correction_params
    params.require(:stock_correction).permit(:location, :correction_date, :reason, :notes)
  end

  def stock_for_location(product, location)
    case location
    when 'lagoa_seca'
      product.stock_lagoa_seca || 0
    when 'bh_shopping'
      product.stock_bh_shopping || 0
    when 'rj'
      product.stock_rj || 0
    else
      0
    end
  end

  def fetch_shopify_stock(product, location)
    return nil unless product.shopify_variant_id.present?
    
    begin
      Rails.logger.info "Fetching real-time stock for #{product.sku} at #{location}"
      stock_result = StockService.check_stock(product.shopify_variant_id, 1, location)
      
      # Extrair o valor numérico do resultado
      stock = if stock_result.is_a?(Hash)
                stock_result[:available_quantity] || stock_result['available_quantity'] || 0
              else
                stock_result.to_i
              end
      
      Rails.logger.info "Real-time stock for #{product.sku}: #{stock}"
      stock
    rescue => e
      Rails.logger.error "Error fetching Shopify stock for #{product.sku}: #{e.message}"
      nil
    end
  end

  def fetch_real_time_stock_for_items(items)
    items.each do |item|
      if item.product.shopify_variant_id.present?
        real_stock = fetch_shopify_stock(item.product, @stock_correction.location)
        
        # Adicionar atributos virtuais para exibição
        item.define_singleton_method(:real_stock) { real_stock || stock_for_location(item.product, @stock_correction.location) }
        item.define_singleton_method(:stock_source) do
          if real_stock
            'shopify_real_time'
          elsif item.product.shopify_variant_id.present?
            'database_fallback'
          else
            'no_shopify_id'
          end
        end
      else
        item.define_singleton_method(:real_stock) { stock_for_location(item.product, @stock_correction.location) }
        item.define_singleton_method(:stock_source) { 'no_shopify_id' }
      end
    end
  end

  def sync_item_with_shopify(item)
    return unless item.product.shopify_variant_id.present?
    
    begin
      result = ShopifyInventoryService.update_inventory(
        item.product,
        @stock_correction.location,
        item.corrected_stock || item.current_stock,
        'correction'
      )
      
      if result[:success]
        item.update!(
          shopify_sync_status: 'synced',
          shopify_sync_error: nil,
          last_shopify_sync_at: Time.current
        )
        Rails.logger.info "Successfully synced #{item.product.sku} with Shopify"
      else
        item.update!(
          shopify_sync_status: 'error',
          shopify_sync_error: result[:message],
          last_shopify_sync_at: Time.current
        )
        Rails.logger.error "Failed to sync #{item.product.sku} with Shopify: #{result[:message]}"
        raise StandardError, result[:message]
      end
    rescue => e
      item.update!(
        shopify_sync_status: 'error',
        shopify_sync_error: e.message,
        last_shopify_sync_at: Time.current
      )
      
      Rails.logger.error "Failed to sync #{item.product.sku} with Shopify: #{e.message}"
      raise e
    end
  end

  def create_correction_items(stock_correction)
    Rails.logger.info "Creating correction items for stock_correction #{stock_correction.id} in location #{stock_correction.location}"
    
    # Buscar apenas produtos com SKU e shopify_inventory_item_id válidos
    products_count = 0
    Product.where.not(sku: [nil, ''])
           .where.not(shopify_inventory_item_id: [nil, ''])
           .find_in_batches(batch_size: 100) do |products_batch|
      items_data = products_batch.map do |product|
        current_stock = case stock_correction.location
                       when 'lagoa_seca'
                         product.stock_lagoa_seca&.to_i || 0
                       when 'bh_shopping'
                         product.stock_bh_shopping&.to_i || 0
                       when 'rj'
                         product.stock_rj&.to_i || 0
                       else
                         0
                       end
        
        products_count += 1
        
        {
          stock_correction_id: stock_correction.id,
          product_id: product.id,
          current_stock: current_stock,
          stock_before: current_stock, # Salvar o estoque inicial
          checked: false,
          needs_correction: false,
          executed: false,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      
      StockCorrectionItem.insert_all(items_data)
    end
    
    Rails.logger.info "Created #{products_count} correction items"
  end
end
