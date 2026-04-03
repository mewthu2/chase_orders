class StockCorrectionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_stock_correction, only: %i[
    show edit update destroy finalize_correction execute_all
    save_item_correction reopen retry_shopify_sync
  ]
  before_action :check_edit_permission, only: %i[edit update save_item_correction]
  before_action :check_admin_permission, only: %i[destroy]

  def index
    @per_page = (params[:per_page] || 10).to_i
    @current_page = (params[:page] || 1).to_i
    @locations_kpi = Location.order(:name)

    query = apply_filters(base_query)

    @total_corrections = query.count
    @total_pages = (@total_corrections.to_f / @per_page).ceil

    offset = (@current_page - 1) * @per_page

    @stock_corrections = query.order(created_at: :desc)
                              .includes(:stock_correction_items)
                              .limit(@per_page)
                              .offset(offset)
  end

  def show
    setup_pagination

    find_search_item if params[:search_term].present?

    load_processed_items
    fetch_real_time_stock_for_items([@search_item].compact)

    build_stats
  end

  def new
    @stock_correction = StockCorrection.new
    @available_locations = current_user.available_locations_for_user

    @location = params[:location] || current_user.default_location
    @location = current_user.default_location unless current_user.can_access_location?(@location)
  end

  def create
    @stock_correction = StockCorrection.new(stock_correction_params)
    @stock_correction.status ||= 'pending'

    unless current_user.can_access_location?(@stock_correction.location)
      flash.now[:alert] = 'Você não tem permissão para criar conferências nesta location'
      @available_locations = current_user.available_locations_for_user
      return render :new, status: :unprocessable_entity
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
    setup_pagination

    find_search_item if params[:search_term].present?

    load_processed_items
    fetch_real_time_stock_for_items([@search_item].compact)

    build_stats
  end

  def update
    if !current_user.admin? &&
       (@stock_correction.location != stock_correction_params[:location] ||
        @stock_correction.correction_date.to_s != stock_correction_params[:correction_date])

      return redirect_to edit_stock_correction_path(@stock_correction),
                         alert: 'Apenas administradores podem alterar location e data.'
    end

    if @stock_correction.update(stock_correction_params)
      redirect_to edit_stock_correction_path(@stock_correction), notice: 'Conferência atualizada com sucesso!'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @stock_correction.soft_delete!
    redirect_to stock_corrections_path, notice: 'Conferência removida com sucesso!'
  rescue StandardError => e
    redirect_to stock_corrections_path, alert: "Erro ao remover conferência: #{e.message}"
  end

  def finalize_correction
    execute_pending_items
    retry_failed_shopify_syncs

    @stock_correction.update!(status: 'executed', executed_at: Time.current)

    redirect_to stock_corrections_path, notice: 'Conferência finalizada com sucesso!'
  rescue StandardError => e
    Rails.logger.error e
    redirect_to stock_corrections_path, alert: "Erro ao finalizar conferência: #{e.message}"
  end

  def execute_all
    pending_items = @stock_correction.stock_correction_items.where(shopify_sync_status: 'error')

    return redirect_to stock_corrections_path, alert: 'Não há correções pendentes.' if pending_items.empty?

    @stock_correction.start_integration!

    SyncShopifyCorrectionsJob.perform_now(@stock_correction.id, current_user.id, pending_items)

    redirect_to stock_corrections_path,
                notice: "Processamento iniciado em background (#{pending_items.count} itens)"
  rescue StandardError => e
    @stock_correction.fail_integration!(e.message)
    redirect_to stock_corrections_path,
                alert: "Erro ao iniciar processamento: #{e.message}"
  end

  def reopen
    return redirect_to stock_corrections_path, alert: 'Apenas administradores podem reabrir.' unless current_user.admin?

    @stock_correction.update(status: 'pending', executed_at: nil)

    redirect_to stock_corrections_path,
                notice: 'Conferência reaberta com sucesso!'
  end

  def save_item_correction
    item = @stock_correction.stock_correction_items
                            .find_or_initialize_by(product_id: params[:product_id])

    if item.new_record?
      product = Product.find(params[:product_id])
      current_stock = stock_for_location(product, @stock_correction.location)
      item.current_stock = current_stock
      item.stock_before = current_stock
    end

    item.assign_attributes(
      corrected_stock: params[:corrected_stock],
      correction_reason: params[:correction_reason],
      needs_correction: true,
      executed: false
    )

    if item.save && item.execute_correction!(with_shopify_integration: true)
      render json: { success: true, message: 'Correção aplicada com sucesso!' }
    else
      render json: { success: false, message: 'Erro ao executar correção.' }
    end
  rescue StandardError => e
    render json: { success: false, message: e.message }
  end

  def retry_shopify_sync
    item = @stock_correction.stock_correction_items.find(params[:item_id])

    if sync_item_with_shopify!(item)
      render json: { success: true, message: 'Sincronizado com sucesso!' }
    else
      render json: { success: false, message: item.shopify_sync_error }
    end
  end

  private

  def base_query
    if current_user.admin?
      StockCorrection.active
    else
      StockCorrection.active.where(location: current_user.allowed_location_keys)
    end
  end

  def apply_filters(query)
    query = query.where(location: params[:location]) if params[:location].present?

    if params[:status].present?
      query = case params[:status]
              when 'pending'
                query.where(status: [nil, 'pending'])
              when 'executed'
                query.where(status: 'executed')
              else
                query
              end
    end

    if params[:date_filter].present?
      date = Date.parse(params[:date_filter])
      query = query.where(correction_date: date.beginning_of_day..date.end_of_day)
    end

    query
  end

  def setup_pagination
    @per_page = (params[:per_page] || 20).to_i
    @current_page = (params[:page] || 1).to_i
  end

  def find_search_item
    @search_term = params[:search_term].strip
    product = Product.find_by(sku: @search_term)

    if product
      existing_item = @stock_correction.stock_correction_items.find_by(product:)

      if existing_item
        @search_item = existing_item
      else
        current_stock = stock_for_location(product, @stock_correction.location)

        @search_item = @stock_correction.stock_correction_items.build(
          product:,
          current_stock:,
          corrected_stock: nil,
          needs_correction: false,
          executed: false
        )
      end

      @product_images = fetch_shopify_product_images_for(product, @stock_correction.location)
    else
      @search_error = 'Produto não encontrado'
    end
  end

  def load_processed_items
    @total_processed = @stock_correction.stock_correction_items
                                        .where(needs_correction: true)
                                        .count

    @total_pages = (@total_processed.to_f / @per_page).ceil

    offset = (@current_page - 1) * @per_page

    @processed_items = @stock_correction.stock_correction_items
                                        .where(needs_correction: true)
                                        .includes(:product)
                                        .order(:created_at)
                                        .limit(@per_page)
                                        .offset(offset)
  end

  def build_stats
    @stats = {
      total: @stock_correction.stock_correction_items.count,
      corrections: @stock_correction.stock_correction_items.where(needs_correction: true).count,
      executed: @stock_correction.stock_correction_items.where(needs_correction: true, executed: true).count
    }
  end

  def execute_pending_items
    pending_items = @stock_correction.stock_correction_items
                                     .where(needs_correction: true, executed: false)

    pending_items.each do |item|
      item.execute_correction!(with_shopify_integration: true)
    end
  end

  def retry_failed_shopify_syncs
    items = @stock_correction.stock_correction_items
                             .where(needs_correction: true, executed: true)
                             .where('shopify_sync_status IS NULL OR shopify_sync_status IN (?)', %w[error pending])

    items.each { |item| sync_item_with_shopify!(item) }
  end

  def sync_item_with_shopify!(item)
    result = ShopifyInventoryService.update_inventory(
      item.product,
      @stock_correction.location,
      item.corrected_stock || item.current_stock
    )

    if result[:success]
      item.update!(shopify_sync_status: 'synced', last_shopify_sync_at: Time.current)
      true
    else
      item.update!(shopify_sync_status: 'error', shopify_sync_error: result[:message])
      false
    end
  end

  def set_stock_correction
    scope = current_user.admin? ? StockCorrection.active : StockCorrection.active.where(location: current_user.allowed_location_keys)
    @stock_correction = scope.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to stock_corrections_path, alert: 'Conferência não encontrada.'
  end

  def check_edit_permission
    return unless @stock_correction.status == 'executed' && !current_user.admin?
    redirect_to stock_correction_path(@stock_correction),
                alert: 'Apenas administradores podem editar conferências finalizadas.'
  end

  def check_admin_permission
    return if current_user.admin?
    redirect_to stock_corrections_path, alert: 'Apenas administradores podem executar esta ação.'
  end

  def stock_correction_params
    params.require(:stock_correction).permit(:location, :correction_date, :reason, :notes)
  end

  def stock_for_location(product, location)
    field = "stock_#{location}"
    product.respond_to?(field) ? product.public_send(field).to_i : 0
  end

  def fetch_shopify_stock(product, location)
    return nil unless product.shopify_variant_id.present?

    stock_result = StockService.check_stock(product.shopify_variant_id, location)

    if stock_result.is_a?(Hash)
      stock_result[:available_quantity] || stock_result['available_quantity'] || 0
    else
      stock_result.to_i
    end
  rescue StandardError
    nil
  end

  def fetch_real_time_stock_for_items(items)
    location = @stock_correction&.location

    items.each do |item|
      next unless item&.product

      if item.product.shopify_variant_id.present?
        real_stock = fetch_shopify_stock(item.product, location)

        fallback_stock = stock_for_location(item.product, location)

        item.define_singleton_method(:real_stock) do
          real_stock || fallback_stock
        end

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
        current_stock = stock_for_location(item.product, location)

        item.define_singleton_method(:real_stock) { current_stock }
        item.define_singleton_method(:stock_source) { 'no_shopify_id' }
      end
    end
  end

  def fetch_shopify_product_images_for(product, store_type)
    return [] unless product&.shopify_variant_id.present?

    config = ShopifyIntegrationService.get_store_config_static(store_type)
    return [] unless config

    session = ShopifyIntegrationService.create_shopify_session_static(config[:access_token])
    client = ShopifyAPI::Clients::Rest::Admin.new(session:)

    variant_response = client.get(path: "variants/#{product.shopify_variant_id}.json")
    product_id = variant_response.body.dig('variant', 'product_id')
    return [] unless product_id

    images_response = client.get(path: "products/#{product_id}/images.json")
    images = images_response.body['images'] || []

    images.first(4).map { |img| img['src'] }.compact
  rescue StandardError
    []
  end

  def create_correction_items(stock_correction)
    Product.where.not(sku: [nil, ''])
           .where.not(shopify_inventory_item_id: [nil, ''])
           .find_in_batches(batch_size: 100) do |products_batch|

      items_data = products_batch.map do |product|
        current_stock = stock_for_location(product, stock_correction.location)

        {
          stock_correction_id: stock_correction.id,
          product_id: product.id,
          current_stock: current_stock,
          stock_before: current_stock,
          checked: false,
          needs_correction: false,
          executed: false,
          created_at: Time.current,
          updated_at: Time.current
        }
      end

      StockCorrectionItem.insert_all(items_data) if items_data.any?
    end
  end
end