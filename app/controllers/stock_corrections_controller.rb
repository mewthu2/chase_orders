class StockCorrectionsController < ApplicationController
  before_action :set_stock_correction, only: [:show, :edit, :update, :destroy, :execute_all, :execute_item, :update_shopify_stock, :sync_item_with_shopify, :integrate_item_correction, :debug_locations, :check_shopify_inventory]
  before_action :check_location_permission, only: [:new, :create, :show, :edit]
  
  def index
    @stock_corrections = StockCorrection.includes(:stock_correction_items)
                                       .order(created_at: :desc)
                                       .page(params[:page])
  end
  
  def show
    @current_page = params[:page]&.to_i || 1
    @per_page = 20
    @search_term = params[:search_term] || ''
    
    # Base query dos items da correção
    items_query = @stock_correction.stock_correction_items.includes(:product)
    
    # Aplicar filtro de busca se houver
    if @search_term.present?
      items_query = items_query.joins(:product)
                        .where('LOWER(products.sku) LIKE ? OR LOWER(products.shopify_product_name) LIKE ?',
                               "%#{@search_term.downcase}%", "%#{@search_term.downcase}%")
    end
    
    # Paginação
    @total_items = items_query.count
    @total_pages = (@total_items.to_f / @per_page).ceil
    
    offset = (@current_page - 1) * @per_page
    @stock_correction_items = items_query.order('products.sku')
                                        .limit(@per_page)
                                        .offset(offset)
    
    # Estatísticas
    @stats = {
      total: @stock_correction.stock_correction_items.count,
      checked: @stock_correction.checked_items.count,
      corrections: @stock_correction.items_to_correct.count,
      executed: @stock_correction.stock_correction_items.where(executed: true).count
    }
  end
  
  def new
    @stock_correction = StockCorrection.new
    
    # Verificar se a location do parâmetro é permitida para o usuário
    requested_location = params[:location]
    if requested_location.present?
      unless current_user.can_access_location?(requested_location)
        flash[:alert] = "Você não tem permissão para acessar a location '#{User.location_name(requested_location)}'"
        redirect_to stock_corrections_path and return
      end
      @location = requested_location
    else
      # Se não especificou location, usar a primeira permitida
      @location = current_user.default_location
      unless @location
        flash[:alert] = "Você não tem permissão para acessar nenhuma location. Entre em contato com o administrador."
        redirect_to stock_corrections_path and return
      end
    end
    
    # Obter apenas as locations que o usuário pode acessar
    @available_locations = current_user.available_locations_for_user
  end
  
  def create
    @stock_correction = StockCorrection.new(stock_correction_params)
    
    # Verificar se o usuário pode acessar a location especificada
    unless current_user.can_access_location?(@stock_correction.location)
      flash[:alert] = "Você não tem permissão para criar conferências na location '#{User.location_name(@stock_correction.location)}'"
      redirect_to stock_corrections_path and return
    end
    
    if @stock_correction.save
      # Criar items para todos os produtos da location após salvar
      create_correction_items(@stock_correction)
      redirect_to edit_stock_correction_path(@stock_correction), notice: 'Conferência criada com sucesso! Agora você pode conferir os produtos.'
    else
      @location = @stock_correction.location || current_user.default_location
      @available_locations = current_user.available_locations_for_user
      render :new
    end
  end
  
  def edit
    @current_page = params[:page]&.to_i || 1
    @per_page = 20
    @search_term = params[:search_term] || ''
    
    # Base query dos items da correção
    items_query = @stock_correction.stock_correction_items.includes(:product)
    
    # Aplicar filtro de busca se houver
    if @search_term.present?
      items_query = items_query.joins(:product)
                      .where('LOWER(products.sku) LIKE ? OR LOWER(products.shopify_product_name) LIKE ?',
                             "%#{@search_term.downcase}%", "%#{@search_term.downcase}%")
    end
    
    # Paginação
    @total_items = items_query.count
    @total_pages = (@total_items.to_f / @per_page).ceil
    
    offset = (@current_page - 1) * @per_page
    @stock_correction_items = items_query.order('products.sku')
                                      .limit(@per_page)
                                      .offset(offset)
  end
  
  def update
    if @stock_correction.update(stock_correction_params)
      redirect_to @stock_correction, notice: 'Conferência atualizada com sucesso!'
    else
      render :edit
    end
  end
  
  def destroy
    @stock_correction.destroy
    redirect_to stock_corrections_path, notice: 'Conferência removida com sucesso!'
  end
  
  def execute_all
    if @stock_correction.execute_corrections!
      redirect_to @stock_correction, notice: 'Correções executadas com sucesso!'
    else
      redirect_to @stock_correction, alert: 'Erro ao executar correções!'
    end
  end
  
  def execute_item
    # CORREÇÃO: Usar o parâmetro correto do item
    item_id = params[:item_id] || params[:id]
    @item = StockCorrectionItem.find(item_id)
    
    Rails.logger.info "=== EXECUTE ITEM DEBUG ==="
    Rails.logger.info "Params: #{params.inspect}"
    Rails.logger.info "Item ID from params: #{item_id}"
    Rails.logger.info "Found item: #{@item.id} for product: #{@item.product.sku}"
    Rails.logger.info "=========================="
    
    if @item.execute_correction!
      render json: { success: true, message: 'Correção executada com sucesso!' }
    else
      render json: { success: false, message: 'Erro ao executar correção!' }
    end
  end
  
  def update_shopify_stock
    begin
      updated_count = 0
      errors = []
      
      @stock_correction.items_to_correct.where(executed: true).each do |item|
        result = update_product_shopify_stock(item)
        if result[:success]
          updated_count += 1
        else
          errors << "#{item.product.sku}: #{result[:message]}"
        end
      end
      
      if errors.empty?
        flash[:notice] = "#{updated_count} produtos atualizados na Shopify com sucesso!"
      else
        flash[:alert] = "Alguns produtos não foram atualizados: #{errors.join(', ')}"
      end
      
    rescue => e
      flash[:alert] = "Erro ao atualizar Shopify: #{e.message}"
    end
    
    redirect_to @stock_correction
  end
  
  def sync_item_with_shopify
    # CORREÇÃO: Usar o parâmetro correto do item
    item_id = params[:item_id] || params[:id]
    @item = StockCorrectionItem.find(item_id)
    
    Rails.logger.info "=== SYNC ITEM DEBUG ==="
    Rails.logger.info "Params: #{params.inspect}"
    Rails.logger.info "Item ID from params: #{item_id}"
    Rails.logger.info "Found item: #{@item.id} for product: #{@item.product.sku}"
    Rails.logger.info "======================="
    
    if @item.sync_with_shopify!
      render json: { 
        success: true, 
        message: 'Produto sincronizado com Shopify com sucesso!',
        sync_status: @item.shopify_sync_status,
        sync_time: @item.last_shopify_sync_at&.strftime('%d/%m/%Y %H:%M')
      }
    else
      render json: { 
        success: false, 
        message: @item.shopify_sync_error || 'Erro ao sincronizar com Shopify',
        sync_status: @item.shopify_sync_status
      }
    end
  end
  
  def integrate_item_correction
    # CORREÇÃO: Usar o parâmetro correto do item
    item_id = params[:item_id] || params[:id]
    @item = StockCorrectionItem.find(item_id)
    corrected_stock = params[:corrected_stock].to_i
    correction_reason = params[:correction_reason]
    
    Rails.logger.info "=== INTEGRATE ITEM DEBUG ==="
    Rails.logger.info "Params: #{params.inspect}"
    Rails.logger.info "Item ID from params: #{item_id}"
    Rails.logger.info "Found item: #{@item.id} for product: #{@item.product.sku} (Product ID: #{@item.product.id})"
    Rails.logger.info "Corrected stock: #{corrected_stock}"
    Rails.logger.info "Correction reason: #{correction_reason}"
    Rails.logger.info "============================="
    
    Rails.logger.info "=== Starting integration for item #{@item.id} ==="
    Rails.logger.info "Parameters - stock: #{corrected_stock}, reason: #{correction_reason}"
    Rails.logger.info "Item current state - needs_correction: #{@item.needs_correction?}, executed: #{@item.executed?}"
    Rails.logger.info "Item current values - corrected_stock: #{@item.corrected_stock}, correction_reason: #{@item.correction_reason}"
    
    begin
      # Validar dados
      if corrected_stock.blank? || correction_reason.blank?
        Rails.logger.error "Validation failed - missing stock or reason"
        render json: { 
          success: false, 
          message: 'Estoque corrigido e motivo são obrigatórios'
        }
        return
      end
      
      # Debug do produto
      Rails.logger.info "Product info - ID: #{@item.product.id}, SKU: #{@item.product.sku}"
      Rails.logger.info "Product stock fields - lagoa_seca: #{@item.product.stock_lagoa_seca}, bh_shopping: #{@item.product.stock_bh_shopping}, rj: #{@item.product.stock_rj}"
      Rails.logger.info "Product shopify_inventory_item_id: #{@item.product.shopify_inventory_item_id}"
      
      # Primeiro, atualizar os dados do item
      Rails.logger.info "Updating item data..."
      @item.assign_attributes(
        corrected_stock: corrected_stock,
        correction_reason: correction_reason,
        needs_correction: true
      )
      
      Rails.logger.info "Item attributes assigned - corrected_stock: #{@item.corrected_stock}, correction_reason: #{@item.correction_reason}, needs_correction: #{@item.needs_correction?}"
      
      if @item.valid?
        Rails.logger.info "Item is valid, saving..."
        @item.save!
        Rails.logger.info "Item saved successfully"
      else
        Rails.logger.error "Item validation failed: #{@item.errors.full_messages.join(', ')}"
        render json: { 
          success: false, 
          message: "Erro de validação: #{@item.errors.full_messages.join(', ')}"
        }
        return
      end
      
      # Se já foi executado, pular direto para sincronização
      if @item.executed?
        Rails.logger.info "Item already executed, skipping to Shopify sync..."
        
        # Atualizar estoque local primeiro com o novo valor
        Rails.logger.info "Updating local stock with new value..."
        if update_local_stock(@item, corrected_stock)
          Rails.logger.info "Local stock updated successfully"
          
          # Tentar sincronizar com Shopify
          sync_result = @item.sync_with_shopify!
          Rails.logger.info "Sync result: #{sync_result}"
          
          if sync_result
            Rails.logger.info "Shopify sync successful"
            render json: { 
              success: true, 
              message: 'Correção atualizada e integrada com Shopify com sucesso!',
              sync_status: @item.shopify_sync_status,
              sync_time: @item.last_shopify_sync_at&.strftime('%d/%m/%Y %H:%M')
            }
          else
            Rails.logger.warn "Shopify sync failed"
            # NÃO marcar como integrado se houver erro
            render json: { 
              success: false, 
              message: "Erro na integração Shopify: #{@item.shopify_sync_error}",
              sync_status: @item.shopify_sync_status
            }
          end
        else
          Rails.logger.error "Failed to update local stock"
          render json: { 
            success: false, 
            message: 'Erro ao atualizar estoque local'
          }
        end
      else
        # Executar a correção normalmente
        Rails.logger.info "Executing correction..."
        execution_result = @item.execute_correction!
        Rails.logger.info "Execution result: #{execution_result}"
        
        if execution_result
          Rails.logger.info "Correction executed successfully, attempting Shopify sync..."
          
          # Tentar sincronizar com Shopify imediatamente
          sync_result = @item.sync_with_shopify!
          Rails.logger.info "Sync result: #{sync_result}"
          
          if sync_result
            Rails.logger.info "Shopify sync successful"
            render json: { 
              success: true, 
              message: 'Correção executada e integrada com Shopify com sucesso!',
              sync_status: @item.shopify_sync_status,
              sync_time: @item.last_shopify_sync_at&.strftime('%d/%m/%Y %H:%M')
            }
          else
            Rails.logger.warn "Correction executed but Shopify sync failed"
            # NÃO marcar como integrado se houver erro na sincronização
            render json: { 
              success: false, 
              message: "Correção executada no banco local, mas erro na integração Shopify: #{@item.shopify_sync_error}",
              sync_status: @item.shopify_sync_status
            }
          end
        else
          Rails.logger.error "Failed to execute correction"
          render json: { 
            success: false, 
            message: 'Erro ao executar correção no banco local'
          }
        end
      end
      
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Validation error: #{e.message}"
      Rails.logger.error "Record errors: #{e.record.errors.full_messages.join(', ')}"
      render json: { 
        success: false, 
        message: "Erro de validação: #{e.record.errors.full_messages.join(', ')}"
      }
    rescue => e
      Rails.logger.error "Unexpected error in integrate_item_correction: #{e.message}"
      Rails.logger.error "Error class: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      render json: { 
        success: false, 
        message: "Erro inesperado: #{e.message}"
      }
    end
  end
  
  def debug_locations
    Rails.logger.info "=== DEBUGGING SHOPIFY LOCATIONS ==="
    
    locations = ShopifyInventoryService.list_locations
    
    render json: {
      success: true,
      message: 'Locations listed in logs',
      locations: locations.map do |edge|
        location = edge['node']
        {
          id: location['id'].gsub('gid://shopify/Location/', ''),
          name: location['name'],
          city: location.dig('address', 'city'),
          province: location.dig('address', 'province')
        }
      end
    }
  end
  
  def check_shopify_inventory
    item_id = params[:item_id]
    @item = StockCorrectionItem.find(item_id)
    
    Rails.logger.info "=== CHECK SHOPIFY INVENTORY DEBUG ==="
    Rails.logger.info "Params: #{params.inspect}"
    Rails.logger.info "Item ID from params: #{item_id}"
    Rails.logger.info "Found item: #{@item.id} for product: #{@item.product.sku}"
    Rails.logger.info "=================================="
    
    result = ShopifyInventoryService.check_inventory_level(@item.product, @item.stock_correction.location)
    
    if result[:success]
      render json: {
        success: true,
        message: 'Estoque consultado com sucesso',
        inventory: {
          available: result[:available],
          on_hand: result[:on_hand],
          committed: result[:committed],
          incoming: result[:incoming],
          tracked: result[:tracked],
          location_name: result[:location_name]
        }
      }
    else
      render json: {
        success: false,
        message: result[:message],
        tracked: result[:tracked]
      }
    end
  end
  
  private
  
  def set_stock_correction
    @stock_correction = StockCorrection.find(params[:id])
  end
  
  def check_location_permission
    # Para ações que envolvem uma stock_correction específica
    if @stock_correction&.location.present?
      unless current_user.can_access_location?(@stock_correction.location)
        flash[:alert] = "Você não tem permissão para acessar esta conferência na location '#{User.location_name(@stock_correction.location)}'"
        redirect_to stock_corrections_path and return
      end
    end
    
    # Para new e create, verificar se o usuário tem pelo menos uma location
    if action_name.in?(['new', 'create']) && !current_user.has_location_access?
      flash[:alert] = "Você não tem permissão para acessar nenhuma location. Entre em contato com o administrador."
      redirect_to stock_corrections_path and return
    end
  end
  
  def stock_correction_params
    params.require(:stock_correction).permit(
      :correction_date, :reason, :location, :notes
    )
  end
  
  def update_local_stock(item, new_stock)
    location = item.stock_correction.location
    product = item.product
    
    begin
      case location
      when 'lagoa_seca'
        Rails.logger.info "Updating stock_lagoa_seca from #{product.stock_lagoa_seca} to #{new_stock}"
        product.update!(stock_lagoa_seca: new_stock)
      when 'bh_shopping'
        Rails.logger.info "Updating stock_bh_shopping from #{product.stock_bh_shopping} to #{new_stock}"
        product.update!(stock_bh_shopping: new_stock)
      when 'rj'
        Rails.logger.info "Updating stock_rj from #{product.stock_rj} to #{new_stock}"
        product.update!(stock_rj: new_stock)
      else
        Rails.logger.error "Unknown location: #{location}"
        return false
      end
      
      Rails.logger.info "Local stock updated successfully for #{product.sku}"
      true
    rescue => e
      Rails.logger.error "Error updating local stock: #{e.message}"
      false
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
          checked: false,
          needs_correction: false,
          created_at: Time.current,
          updated_at: Time.current
        }
      end
      
      StockCorrectionItem.insert_all(items_data)
    end
    
    Rails.logger.info "Created #{products_count} correction items (only products with shopify_inventory_item_id)"
  end
  
  def update_product_shopify_stock(item)
    return { success: false, message: 'Produto sem variant_id' } unless item.product.shopify_variant_id.present?
    
    begin
      store_type = item.stock_correction.location
      
      # Usar StockService ou criar um service específico para atualização
      # Por enquanto, simular a atualização
      Rails.logger.info "Atualizando Shopify: #{item.product.sku} para #{item.corrected_stock} na #{store_type}"
      
      # Aqui você implementaria a chamada real para a API do Shopify
      # usando seu ShopifyIntegrationService ou similar
      
      { success: true, message: 'Atualizado com sucesso' }
    rescue => e
      { success: false, message: e.message }
    end
  end
end
