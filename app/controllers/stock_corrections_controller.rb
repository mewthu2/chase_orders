class StockCorrectionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_stock_correction, only: [:show, :edit, :update, :destroy, :finalize_correction, :execute_all, :save_item_correction, :reopen, :sync_with_shopify]
  before_action :check_edit_permission, only: [:edit, :update, :save_item_correction]
  before_action :check_admin_permission, only: [:destroy, :sync_with_shopify]

  def index
    @per_page = 10
    @current_page = (params[:page] || 1).to_i
    offset = (@current_page - 1) * @per_page

    if current_user.admin?
      @stock_corrections = StockCorrection.active
                                          .includes(:stock_correction_items)
                                          .order(created_at: :desc)
                                          .limit(@per_page)
                                          .offset(offset)

      @total_corrections = StockCorrection.active.count
      @pending_corrections = StockCorrection.active.where(status: [nil, 'pending']).count
      @completed_corrections = StockCorrection.active.where(status: 'executed').count
      @synced_corrections = StockCorrection.active
                                           .joins(:stock_correction_items)
                                           .where(stock_correction_items: { 
                                             last_shopify_sync_at: Date.current.beginning_of_day..Date.current.end_of_day 
                                           })
                                           .distinct.count
    else
      allowed_locations = current_user.allowed_location_keys
      @stock_corrections = StockCorrection.active
                                          .where(location: allowed_locations)
                                          .includes(:stock_correction_items)
                                          .order(created_at: :desc)
                                          .limit(@per_page)
                                          .offset(offset)

      base_corrections = StockCorrection.active.where(location: allowed_locations)
      @total_corrections = base_corrections.count
      @pending_corrections = base_corrections.where(status: [nil, 'pending']).count
      @completed_corrections = base_corrections.where(status: 'executed').count
      @synced_corrections = base_corrections.joins(:stock_correction_items)
                                            .where(stock_correction_items: { 
                                              last_shopify_sync_at: Date.current.beginning_of_day..Date.current.end_of_day 
                                            })
                                            .distinct.count
    end

    @total_pages = (@total_corrections.to_f / @per_page).ceil
  end

  def show
    @per_page = 20
    @current_page = (params[:page] || 1).to_i

    if params[:search_term].present?
      @search_term = params[:search_term].strip
      @search_item = @stock_correction.stock_correction_items
                                      .joins(:product)
                                      .where(products: { sku: @search_term })
                                      .includes(:product)
                                      .first
    end

    @total_processed = @stock_correction.stock_correction_items.where(needs_correction: true).count
    @total_pages = (@total_processed.to_f / @per_page).ceil

    offset = (@current_page - 1) * @per_page
    @processed_items = @stock_correction.stock_correction_items
                                        .where(needs_correction: true)
                                        .includes(:product)
                                        .order(:created_at)
                                        .limit(@per_page)
                                        .offset(offset)

    fetch_real_time_stock_for_items([@search_item].compact) if @search_item

    @stats = {
      total: @stock_correction.stock_correction_items.count,
      corrections: @stock_correction.stock_correction_items.where(needs_correction: true).count,
      executed: @stock_correction.stock_correction_items.where(needs_correction: true, executed: true).count
    }
  end

  def new
    @stock_correction = StockCorrection.new
    @available_locations = current_user.available_locations_for_user

    @location = params[:location] || current_user.default_location

    @location = current_user.default_location unless current_user.can_access_location?(@location)
  end

  def create
    @stock_correction = StockCorrection.new(stock_correction_params)
    @stock_correction.status = 'pending'

    unless current_user.can_access_location?(@stock_correction.location)
      flash[:alert] = "Você não tem permissão para criar conferências na location '#{User.location_name(@stock_correction.location)}'"
      redirect_to stock_corrections_path and return
    end

    if @stock_correction.save
      create_correction_items(@stock_correction)
      redirect_to edit_stock_correction_path(@stock_correction), notice: 'Conferência criada com sucesso!'
    else
      @available_locations = current_user.available_locations_for_user
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @location = @stock_correction.location

    @per_page = 20
    @current_page = (params[:page] || 1).to_i

    if params[:search_term].present?
      @search_term = params[:search_term].strip
      product = Product.find_by(sku: @search_term)

      if product
        existing_item_with_correction = @stock_correction.stock_correction_items
                                                         .where(product:, needs_correction: true)
                                                         .first

        if existing_item_with_correction
          @search_item = existing_item_with_correction
        else
          existing_item = @stock_correction.stock_correction_items.find_by(product:)

          if existing_item
            @search_item = existing_item
          else
            current_stock = stock_for_location(product, @location)

            @search_item = @stock_correction.stock_correction_items.build(
              product:,
              current_stock:,
              corrected_stock:,
              needs_correction: false,
              executed: false
            )
          end

          real_stock = fetch_shopify_stock(product, @location)
          @search_item.define_singleton_method(:real_stock) { real_stock || current_stock }
          @search_item.define_singleton_method(:stock_source) do
            case
            when real_stock
              'shopify_real_time'
            when product.shopify_variant_id.present?
              'database_fallback'
            else
              'no_shopify_id'
            end
          end
        end
      else
        @search_error = 'Produto não encontrado'
      end
    end

    @total_processed = @stock_correction.stock_correction_items.where(needs_correction: true).count
    @total_pages = (@total_processed.to_f / @per_page).ceil

    offset = (@current_page - 1) * @per_page
    @processed_items = @stock_correction.stock_correction_items
                                        .where(needs_correction: true)
                                        .includes(:product)
                                        .order(:created_at)
                                        .limit(@per_page)
                                        .offset(offset)

    fetch_real_time_stock_for_items([@search_item].compact) if @search_item

    @stats = {
      total: @stock_correction.stock_correction_items.count,
      corrections: @stock_correction.stock_correction_items.where(needs_correction: true).count,
      executed: @stock_correction.stock_correction_items.where(needs_correction: true, executed: true).count
    }
  end

  def update
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
    Rails.logger.info '=== SOFT DELETE ACTION CALLED ==='
    Rails.logger.info "Stock Correction ID: #{@stock_correction.id}"
    Rails.logger.info "Current User: #{current_user.name} (ID: #{current_user.id})"
    Rails.logger.info "Is Admin: #{current_user.admin?}"

    begin
      @stock_correction.soft_delete!
      Rails.logger.info "Stock correction soft deleted successfully"
      redirect_to stock_corrections_path, notice: 'Conferência removida com sucesso!'
    rescue StandardError => e
      Rails.logger.error "Error soft deleting stock correction: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      redirect_to stock_corrections_path, alert: "Erro ao remover conferência: #{e.message}"
    end
  end

  def finalize_correction
    if @stock_correction.update!(status: 'executed', executed_at: Time.current)
      redirect_to stock_corrections_path,
                  notice: 'Conferência finalizada com sucesso!'
    else
      redirect_to stock_corrections_path,
                  alert: 'Erro ao finalizar conferência.'
    end
  rescue StandardError => e
    Rails.logger.error "Erro ao finalizar conferência: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    redirect_to stock_corrections_path,
                alert: "Erro ao finalizar conferência: #{e.message}"
  end

  def execute_all
    pending_items = @stock_correction.stock_correction_items.where(needs_correction: true, executed: false)

    if pending_items.empty?
      redirect_to stock_corrections_path, alert: 'Não há correções pendentes para processar.'
      return
    end

    @stock_correction.start_integration!

    SyncShopifyCorrectionsJob.perform_later(@stock_correction.id, current_user.id)

    Rails.logger.info "SyncShopifyCorrectionsJob enqueued for execute_all on stock_correction #{@stock_correction.id}"

    redirect_to stock_corrections_path,
                notice: "Processamento iniciado em background! #{pending_items.count} correções serão processadas."

  rescue StandardError => e
    Rails.logger.error "Erro ao enfileirar job de processamento: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    @stock_correction.fail_integration!(e.message)

    redirect_to stock_corrections_path,
                alert: "Erro ao iniciar processamento: #{e.message}"
  end

  def sync_with_shopify
    items_to_sync = @stock_correction.stock_correction_items
                                     .where(needs_correction: true, executed: true)

    if items_to_sync.empty?
      redirect_to stock_corrections_path,
                  alert: 'Não há itens executados para sincronizar com a Shopify.'
      return
    end

    @stock_correction.start_integration!

    SyncShopifyCorrectionsJob.perform_later(@stock_correction.id, current_user.id)

    Rails.logger.info "SyncShopifyCorrectionsJob enqueued for stock_correction #{@stock_correction.id}"

    redirect_to stock_corrections_path,
                notice: "Sincronização com Shopify iniciada em background! #{items_to_sync.count} itens serão sincronizados."
  rescue StandardError => e
    Rails.logger.error "Erro ao enfileirar job de sincronização: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    @stock_correction.fail_integration!(e.message)

    redirect_to stock_corrections_path,
                alert: "Erro ao iniciar sincronização: #{e.message}"
  end

  def reopen
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

  def save_item_correction
    product_id = params[:product_id]
    corrected_stock = params[:corrected_stock].to_i
    correction_reason = params[:correction_reason]

    item = @stock_correction.stock_correction_items.find_or_initialize_by(product_id:)

    if item.new_record?
      product = Product.find(product_id)
      current_stock = stock_for_location(product, @stock_correction.location)
      item.current_stock = current_stock
    end

    item.stock_before = item.current_stock || 0 if item.stock_before.blank?

    item.assign_attributes(
      corrected_stock:,
      correction_reason:,
      needs_correction: true,
      executed: false
    )

    if item.save
      Rails.logger.info '=== Executing correction WITH automatic Shopify integration (IMMEDIATE) ==='

      if item.execute_correction!(with_shopify_integration: true)
        render json: {
          success: true,
          message: 'Correção salva e integrada com a Shopify com sucesso!',
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
  rescue StandardError => e
    Rails.logger.error "Erro ao salvar correção: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    render json: { success: false, message: e.message }
  end

  private

  def set_stock_correction
    if current_user.admin?
      @stock_correction = StockCorrection.active.find(params[:id])
    else
      allowed_locations = current_user.allowed_location_keys
      @stock_correction = StockCorrection.active.where(location: allowed_locations).find(params[:id])
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to stock_corrections_path, alert: 'Conferência não encontrada ou sem permissão de acesso.'
  end

  def check_edit_permission
    return unless @stock_correction.status == 'executed' && !current_user.admin?
    redirect_to @stock_correction, alert: 'Apenas administradores podem editar conferências finalizadas.'
  end

  def check_admin_permission
    return unless current_user.admin?
    redirect_to stock_corrections_path, alert: 'Apenas administradores podem executar esta ação.' 
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

      stock = if stock_result.is_a?(Hash)
                stock_result[:available_quantity] || stock_result['available_quantity'] || 0
              else
                stock_result.to_i
              end

      Rails.logger.info "Real-time stock for #{product.sku}: #{stock}"
      stock
    rescue StandardError => e
      Rails.logger.error "Error fetching Shopify stock for #{product.sku}: #{e.message}"
      nil
    end
  end

  def fetch_real_time_stock_for_items(items)
    items.each do |item|
      next unless item&.product

      if item.product.shopify_variant_id.present?
        real_stock = fetch_shopify_stock(item.product, @stock_correction.location)

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
        current_stock = stock_for_location(item.product, @stock_correction.location)
        item.define_singleton_method(:real_stock) { current_stock }
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
    rescue StandardError => e
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

    products_count = 0
    Product.where.not(sku: [nil, ''])
           .where.not(shopify_inventory_item_id: [nil, ''])
           .find_in_batches(batch_size: 100) do |products_batch|
      items_data = products_batch.map do |product|
        current_stock = case stock_correction.location
                        when 'lagoa_seca'
                          product.stock_lagoa_seca.to_i || 0
                        when 'bh_shopping'
                          product.stock_bh_shopping.to_i || 0
                        when 'rj'
                          product.stock_rj.to_i || 0
                        else
                          0
                        end

        products_count += 1

        {
          stock_correction_id: stock_correction.id,
          product_id: product.id,
          current_stock:,
          stock_before: current_stock,
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
