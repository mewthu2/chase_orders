class StockWithdrawalsController < ApplicationController
  guard_screen :stock_withdrawals
  before_action :set_withdrawal, only: [:show, :edit, :update, :destroy, :complete]
  before_action :require_editable, only: [:edit, :update, :destroy]

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
    @withdrawal.items.each(&:mark_for_destruction)
    build_items(@withdrawal)

    if @withdrawal.save
      redirect_to stock_withdrawal_path(@withdrawal), notice: 'Retirada atualizada.'
    else
      prepare_form
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @withdrawal.destroy
    redirect_to stock_withdrawals_path, notice: 'Rascunho de retirada excluído.'
  end

  # Retira do Shopify na hora (sem fila). Em "Tentar novamente" só as linhas pendentes/com falha são enviadas.
  def complete
    summary = StockWithdrawalProcessor.call(@withdrawal, user: current_user)

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

  private

  def set_withdrawal
    @withdrawal = StockWithdrawal.includes(items: [:product, :location]).find(params[:id])
  end

  def require_editable
    return if @withdrawal.editable?

    redirect_to stock_withdrawal_path(@withdrawal), alert: 'Só é possível editar ou excluir uma retirada em rascunho.'
  end

  def header_params
    params.require(:stock_withdrawal).permit(:withdrawal_date, :reason, :notes)
  end

  # Cada célula da grade (produto x location) vira um item; célula em branco é ignorada.
  def build_items(withdrawal)
    rows = params.require(:stock_withdrawal).permit(items: [:product_id, :location_id, :quantity])[:items]
    rows = rows.respond_to?(:values) ? rows.values : Array(rows)
    rows.each do |row|
      next if row[:quantity].blank?

      withdrawal.items.build(product_id: row[:product_id], location_id: row[:location_id], quantity: row[:quantity])
    end
  end

  # Dados da grade: locations, linhas (produto + quantidade por location) e locations marcadas.
  def prepare_form
    @locations = Location.order(:name)
    live_items = @withdrawal.items.reject(&:marked_for_destruction?)
    @rows = live_items.group_by(&:product).map do |product, items|
      product_json(product).merge(quantities: items.to_h { |item| [item.location_id.to_s, item.quantity] })
    end
    @selected_location_ids = (Array(params[:location_ids]).map(&:to_i) + live_items.map(&:location_id)).uniq
  end

  def product_json(product)
    @all_locations ||= Location.order(:id).to_a
    stock = @all_locations.to_h { |location| [location.slug, local_stock(product, location.slug)] }
    { id: product.id, sku: product.sku, name: product.shopify_product_name, image_url: product.image_url, stock: stock }
  end

  def local_stock(product, slug)
    column = "stock_#{slug}"
    product.respond_to?(column) ? product[column].to_i : nil
  end
end
