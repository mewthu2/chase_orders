class StockWithdrawalsController < ApplicationController
  guard_screen :stock_withdrawals
  before_action :set_withdrawal, only: [:show, :edit, :update, :destroy, :complete]
  before_action :require_editable, only: [:edit, :update]

  def index
    scope = StockWithdrawal.includes(:user, items: :location).recent
    scope = scope.where(status: params[:status]) if StockWithdrawal.statuses.key?(params[:status])
    @withdrawals = scope.paginate(page: params[:page], per_page: 20)
  end

  def new
    @withdrawal = StockWithdrawal.new(withdrawal_date: Date.current, reason: 'shrinkage')
    prepare_form
  end

  def create
    @withdrawal = StockWithdrawal.new(header_params.merge(user: current_user))
    build_items(@withdrawal)

    if @withdrawal.save
      redirect_to stock_withdrawal_path(@withdrawal), notice: 'Retirada salva como rascunho. Revise e clique em "Concluir" para retirar do Shopify.'
    else
      prepare_form
      render :new, status: :unprocessable_entity
    end
  end

  def show; end

  def edit
    prepare_form
  end

  def update
    @withdrawal.assign_attributes(header_params)
    @withdrawal.editable_items.each(&:mark_for_destruction) # as já retiradas nunca são tocadas
    build_items(@withdrawal)
    complete_if_nothing_left(@withdrawal)

    if @withdrawal.save
      redirect_to stock_withdrawal_path(@withdrawal), notice: 'Retirada atualizada.'
    else
      prepare_form
      render :edit, status: :unprocessable_entity
    end
  end

  # Só rascunho pode ser excluído. Depois de integrada com o Shopify a retirada fica como registro;
  # para desfazer, reverte-se cada linha retirada (devolve o estoque no Shopify).
  def destroy
    unless @withdrawal.deletable?
      redirect_to stock_withdrawal_path(@withdrawal),
                  alert: 'Esta retirada já foi integrada com o Shopify e não pode ser excluída. Para desfazer, use "Reverter" nas linhas retiradas.'
      return
    end

    @withdrawal.destroy
    redirect_to stock_withdrawals_path, notice: 'Rascunho de retirada excluído.'
  end

  # Retira do Shopify na hora (sem fila). Em "Tentar novamente" só as linhas pendentes/com falha são enviadas.
  def complete
    summary = StockWithdrawalProcessor.call(@withdrawal, user: current_user, allow_negative: params[:allow_negative] == '1')

    if summary.failed.zero?
      redirect_to stock_withdrawal_path(@withdrawal), notice: "Retirada concluída: #{summary.done} linha(s) retirada(s) do Shopify."
    else
      redirect_to stock_withdrawal_path(@withdrawal),
                  alert: "Retirada concluída com falhas: #{summary.done} retirada(s), #{summary.failed} com falha. Veja os motivos abaixo."
    end
  rescue StockWithdrawalProcessor::Error => e
    redirect_to stock_withdrawal_path(@withdrawal), alert: e.message
  end

  def search_product
    query = params[:query].to_s.strip.downcase
    return render(json: { success: true, products: [] }) if query.blank?

    scope = query.split(/\s+/).reduce(Product.where.not(shopify_inventory_item_id: [nil, ''])) do |relation, token|
      relation.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
    end
    render json: { success: true, products: scope.order(:sku).limit(10).map { |product| product_json(product) } }
  end

  # Estoque REAL do Shopify (disponível) de cada produto nas locations marcadas, mais a foto.
  # Uma leitura em lote por location; a falha de uma location não derruba as outras.
  # null = produto não estocado/rastreado naquela location (nunca 0).
  def live_stock
    products = Product.where(id: Array(params[:product_ids]).first(100)).where.not(shopify_inventory_item_id: [nil, ''])
    locations = Location.where(id: Array(params[:location_ids]).first(20))
    stock = products.to_h { |product| [product.id.to_s, {}] }
    errors = {}

    if products.any?
      inventory = ShopifyInventoryService.new
      item_ids = products.map { |product| product.shopify_inventory_item_id.to_s }
      locations.each do |location|
        fetch_location_stock(inventory, location, products, item_ids, stock, errors)
      end
    end

    render json: { success: true, stock: stock, errors: errors, images: products.to_h { |product| [product.id.to_s, image_url_for(product)] } }
  end

  private

  def fetch_location_stock(inventory, location, products, item_ids, stock, errors)
    if location.shopify_location_id.blank?
      errors[location.id.to_s] = "Location #{location.name} sem ID do Shopify"
      products.each { |product| stock[product.id.to_s][location.id.to_s] = nil }
      return
    end

    available = inventory.available_quantities(location.shopify_location_id, item_ids)
    products.each { |product| stock[product.id.to_s][location.id.to_s] = available[product.shopify_inventory_item_id.to_s] }
  rescue StandardError => e
    Rails.logger.error "StockWithdrawalsController#live_stock (location #{location.id}): #{e.class} #{e.message}"
    errors[location.id.to_s] = "Não foi possível consultar o Shopify: #{e.message}"
    products.each { |product| stock[product.id.to_s][location.id.to_s] = nil }
  end

  # Foto guardada; se faltar, busca no Shopify (mesma rotina que o pedido B2B usa). Falha na foto não quebra a tela.
  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil if product.shopify_product_id.blank?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url.presence
  rescue StandardError => e
    Rails.logger.error "StockWithdrawalsController#image_url_for (#{product.sku}): #{e.class} #{e.message}"
    nil
  end

  # Cada ação carrega só o que usa (o Bullet reclama de eager loading que sobra):
  # a página de detalhe mostra produto e location de cada linha; a edição usa só o produto
  # (as locations vêm da lista já carregada); as demais ações não precisam de nenhum.
  def set_withdrawal
    scope = case action_name
            when 'show' then StockWithdrawal.includes(items: [:product, :location])
            when 'edit', 'update' then StockWithdrawal.includes(items: :product)
            else StockWithdrawal
            end
    @withdrawal = scope.find(params[:id])
  end

  def require_editable
    return if @withdrawal.editable?

    redirect_to stock_withdrawal_path(@withdrawal), alert: 'Só é possível editar ou excluir uma retirada em rascunho.'
  end

  # Depois que há linhas retiradas, data e motivo já valem no Shopify e ficam travados (só as observações mudam).
  def header_params
    permitted = @withdrawal&.persisted? && @withdrawal.header_locked? ? [:notes] : [:withdrawal_date, :reason, :notes]
    params.require(:stock_withdrawal).permit(*permitted)
  end

  # Se ao editar não sobrou linha pendente (todas as com falha foram removidas), a retirada está concluída.
  def complete_if_nothing_left(withdrawal)
    return unless withdrawal.partially_failed?

    remaining = withdrawal.items.reject(&:marked_for_destruction?)
    withdrawal.assign_attributes(status: :completed, completed_at: Time.current) if remaining.all?(&:done?)
  end

  # Cada célula da grade (produto x location) vira um item; célula em branco é ignorada.
  def build_items(withdrawal)
    rows = params.require(:stock_withdrawal).permit(items: [:product_id, :location_id, :quantity])[:items]
    rows = rows.respond_to?(:values) ? rows.values : Array(rows)
    rows = rows.reject { |row| row[:quantity].blank? }
    # Produtos das linhas numa consulta só (evita um SELECT por linha ao validar e reexibir o formulário).
    products = Product.where(id: rows.map { |row| row[:product_id] }).index_by(&:id)

    rows.each do |row|
      withdrawal.items.build(product: products[row[:product_id].to_i], product_id: row[:product_id], location_id: row[:location_id], quantity: row[:quantity])
    end
  end

  # Dados da grade: locations, linhas (produto + quantidade por location) e locations marcadas.
  def prepare_form
    @locations = Location.order(:name)
    @locations_by_id = @locations.index_by(&:id)
    live_items = @withdrawal.items.reject { |item| item.marked_for_destruction? || item.locked? }
    @locked_items = @withdrawal.locked_items
    @rows = live_items.group_by(&:product).map do |product, items|
      product_json(product).merge(
        quantities: items.to_h { |item| [item.location_id.to_s, item.quantity] },
        errors: items.select { |item| item.error_message.present? }.to_h { |item| [item.location_id.to_s, item.error_message] }
      )
    end
    @selected_location_ids = (Array(params[:location_ids]).map(&:to_i) + live_items.map(&:location_id)).uniq
  end

  def product_json(product)
    { id: product.id, sku: product.sku, name: product.shopify_product_name, image_url: product.image_url }
  end
end
