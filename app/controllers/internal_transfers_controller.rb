# Transferência interna entre lojas (locations do Shopify). Um pedido tem uma loja de destino
# ("Minha loja é: ...") e reúne itens de várias lojas de origem; cada origem vira uma remessa
# (InternalTransferShipment) com o próprio andamento.
class InternalTransfersController < ApplicationController
  # O aprovador precisa ver e aprovar/reprovar mesmo sem a tela liberada no perfil.
  APPROVER_ACTIONS = %w[index show approve reject].freeze

  guard_screen :internal_transfers, unless: -> { approver? && APPROVER_ACTIONS.include?(action_name) }

  # Correios Log + é uma location de logística do Shopify, sem gerente para reservar/receber:
  # não entra como origem nem como destino de uma transferência entre lojas.
  EXCLUDED_LOCATION_SLUGS = ['log+'].freeze
  before_action :set_transfer, only: [:show, :edit, :update, :destroy, :approve, :reject]
  before_action :require_editable, only: [:edit, :update]
  before_action :require_approver, only: [:approve, :reject]
  helper_method :approver?

  def index
    scope = InternalTransfer.includes(:destination_location, shipments: [:origin_location, :items]).recent
    scope = scope_for_user(scope) unless current_user.admin?
    @approver = InternalTransferConfig.current.approver
    @transfers = scope.paginate(page: params[:page], per_page: 20)
    # Só o nome do solicitante: pré-carregar os User faria o Bullet confundir o current_user (quando
    # ele também é solicitante) com um N+1 de profiles.
    @requester_names = User.where(id: @transfers.map(&:requested_by_id).uniq).pluck(:id, :name).to_h
  end

  def new
    @transfer = InternalTransfer.new(destination_location_id: params[:destination_location_id].presence || default_destination&.id)
    prepare_form
  end

  def create
    @transfer = InternalTransfer.new(header_params.merge(requested_by: current_user))

    unless allowed_destination?(@transfer.destination_location)
      @transfer.errors.add(:destination_location, 'não é uma loja permitida para você')
      prepare_form
      return render :new, status: :unprocessable_entity
    end

    build_shipments(@transfer)

    if @transfer.save
      log_event(@transfer, action: 'created', message: "Transferência criada para #{@transfer.destination_location.name} (#{@transfer.total_quantity} unidade(s)).")
      redirect_to internal_transfer_path(@transfer), notice: 'Transferência criada. Ela precisa ser aprovada antes de as lojas de origem reservarem os itens.'
    else
      prepare_form
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @approver = InternalTransferConfig.current.approver
  end

  def edit
    prepare_form
  end

  def update
    @transfer.assign_attributes(header_params)
    @transfer.shipments.each(&:mark_for_destruction)
    build_shipments(@transfer)
    # Mudou o que foi aprovado: precisa de nova aprovação.
    reapproval = @transfer.approval_aprovada?
    @transfer.assign_attributes(approval_status: :pendente, reviewed_by: nil, reviewed_at: nil) if reapproval

    if @transfer.save
      log_event(@transfer, action: 'updated', message: 'Transferência editada; volta a aguardar aprovação.') if reapproval
      redirect_to internal_transfer_path(@transfer), notice: reapproval ? 'Transferência atualizada. Ela volta a aguardar aprovação.' : 'Transferência atualizada.'
    else
      prepare_form
      render :edit, status: :unprocessable_entity
    end
  end

  # Só dá para excluir enquanto nenhuma remessa saiu do estado aberto.
  def destroy
    unless @transfer.deletable?
      redirect_to internal_transfer_path(@transfer), alert: 'Esta transferência já está em andamento e não pode ser excluída.'
      return
    end

    @transfer.destroy
    redirect_to internal_transfers_path, notice: 'Transferência excluída.'
  end

  def approve
    @transfer.approve!(current_user)
    redirect_to internal_transfer_path(@transfer), notice: 'Transferência aprovada. As lojas de origem já podem reservar os itens.'
  rescue InternalTransfer::NotPending => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  def reject
    @transfer.reject!(current_user, reason: params[:rejection_reason].to_s.strip)
    redirect_to internal_transfer_path(@transfer), notice: 'Transferência reprovada.'
  rescue InternalTransfer::NotPending => e
    redirect_to internal_transfer_path(@transfer), alert: e.message
  end

  def search_product
    query = params[:query].to_s.strip.downcase
    return render(json: { success: true, products: [] }) if query.blank?

    scope = query.split(/\s+/).reduce(Product.where.not(shopify_inventory_item_id: [nil, ''])) do |relation, token|
      relation.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
    end
    render json: { success: true, products: scope.order(:sku).limit(10).map { |product| product_json(product) } }
  end

  # Estoque REAL do Shopify (disponível) de cada produto nas lojas de origem marcadas, mais a foto.
  def live_stock
    products = Product.where(id: Array(params[:product_ids]).first(100)).where.not(shopify_inventory_item_id: [nil, ''])
    locations = Location.where(id: Array(params[:location_ids]).first(20))
    stock = products.to_h { |product| [product.id.to_s, {}] }
    errors = {}

    if products.any?
      inventory = ShopifyInventoryService.new
      item_ids = products.map { |product| product.shopify_inventory_item_id.to_s }
      locations.each { |location| fetch_location_stock(inventory, location, products, item_ids, stock, errors) }
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
    Rails.logger.error "InternalTransfersController#live_stock (location #{location.id}): #{e.class} #{e.message}"
    errors[location.id.to_s] = "Não foi possível consultar o Shopify: #{e.message}"
    products.each { |product| stock[product.id.to_s][location.id.to_s] = nil }
  end

  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil if product.shopify_product_id.blank?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url.presence
  rescue StandardError => e
    Rails.logger.error "InternalTransfersController#image_url_for (#{product.sku}): #{e.class} #{e.message}"
    nil
  end

  # Cada ação carrega só o que usa (eager loading que sobra é o que o Bullet reclama).
  def set_transfer
    scope = case action_name
            when 'show'
              InternalTransfer.includes(:destination_location, :requested_by, events: :user,
                                        shipments: [:origin_location, { items: :product }])
            when 'edit', 'update'
              InternalTransfer.includes(shipments: :items)
            else
              InternalTransfer
            end
    @transfer = scope.find(params[:id])
  end

  def approver?
    @approver_flag = current_user.id == InternalTransferConfig.approver_id if @approver_flag.nil?
    @approver_flag
  end

  def require_approver
    return if approver?

    redirect_to internal_transfer_path(@transfer), alert: 'Só o aprovador configurado pode aprovar ou reprovar transferências.'
  end

  def require_editable
    return if @transfer.editable?

    redirect_to internal_transfer_path(@transfer), alert: 'Esta transferência não pode mais ser editada: alguma remessa já saiu do estado aberto.'
  end

  def header_params
    params.require(:internal_transfer).permit(:destination_location_id, :notes)
  end

  def default_destination
    return nil if current_user.admin?

    transferable_locations.find_by(slug: current_user.allowed_location_keys.first)
  end

  def allowed_destination?(location)
    return false if location.nil? || EXCLUDED_LOCATION_SLUGS.include?(location.slug)

    current_user.admin? || current_user.can_access_location?(location.slug)
  end

  def transferable_locations
    Location.where.not(slug: EXCLUDED_LOCATION_SLUGS)
  end

  # Só pedidos em que a location (por slug) participa, como origem ou destino; o aprovador vê
  # também todos os que aguardam aprovação.
  def scope_for_user(scope)
    slugs = current_user.allowed_location_keys
    ids = slugs.flat_map { |slug| InternalTransfer.involving_location_slug(slug).ids }
    ids += InternalTransfer.approval_pendente.ids if approver?
    scope.where(id: ids.uniq)
  end

  # Cada célula da grade (produto x loja de origem) vira um item; célula em branco é ignorada.
  # As linhas são agrupadas por loja de origem em uma remessa por origem.
  def build_shipments(transfer)
    excluded_ids = Location.where(slug: EXCLUDED_LOCATION_SLUGS).ids
    rows = params.require(:internal_transfer).permit(items: [:product_id, :location_id, :quantity])[:items]
    rows = rows.respond_to?(:values) ? rows.values : Array(rows)
    rows = rows.reject { |row| row[:quantity].blank? || excluded_ids.include?(row[:location_id].to_i) }
    products = Product.where(id: rows.map { |row| row[:product_id] }).index_by(&:id)

    rows.group_by { |row| row[:location_id].to_i }.each do |location_id, group|
      shipment = transfer.shipments.build(origin_location_id: location_id)
      group.each { |row| shipment.items.build(product: products[row[:product_id].to_i], product_id: row[:product_id], quantity: row[:quantity]) }
    end
  end

  # As lojas de origem para a grade nunca incluem a loja de destino escolhida (não dá para
  # transferir de uma loja para ela mesma). Se o admin trocar o destino, a lista de origens só
  # atualiza num novo carregamento da página.
  def prepare_form
    @my_locations = (current_user.admin? ? transferable_locations : transferable_locations.where(slug: current_user.allowed_location_keys)).order(:name)
    @origin_locations = transferable_locations.where.not(id: @transfer.destination_location_id).order(:name)
    live_shipments = @transfer.shipments.reject(&:marked_for_destruction?)
    live_items = live_shipments.flat_map { |shipment| shipment.items.reject(&:marked_for_destruction?) }
    @rows = live_items.group_by(&:product).map do |product, items|
      product_json(product).merge(quantities: items.to_h { |item| [item.internal_transfer_shipment.origin_location_id.to_s, item.quantity] })
    end
    @selected_location_ids = (Array(params[:location_ids]).map(&:to_i) + live_shipments.map(&:origin_location_id)).uniq
  end

  def product_json(product)
    { id: product.id, sku: product.sku, name: product.shopify_product_name, image_url: product.image_url }
  end

  def log_event(transfer, action:, message:)
    InternalTransferEvent.create!(internal_transfer: transfer, user: current_user, action: action, message: message)
  end
end
