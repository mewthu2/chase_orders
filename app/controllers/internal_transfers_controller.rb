# Transferência interna entre lojas (locations do Shopify). Um pedido tem uma loja de destino
# ("Minha loja é: ...") e reúne itens de várias lojas de origem; cada origem vira uma remessa
# (InternalTransferShipment) com o próprio andamento.
class InternalTransfersController < ApplicationController
  # Os aprovadores precisam ver e aprovar/reprovar mesmo sem a tela liberada no perfil.
  APPROVER_ACTIONS = %w[index show approve reject].freeze

  guard_screen :internal_transfers, unless: -> { approver? && APPROVER_ACTIONS.include?(action_name) }

  # Correios Log + é uma location de logística do Shopify, sem gerente para reservar/receber:
  # não entra como origem nem como destino de uma transferência entre lojas.
  EXCLUDED_LOCATION_SLUGS = ['log+'].freeze
  before_action :set_transfer, only: [:show, :edit, :update, :destroy, :approve, :reject]
  before_action :require_editable, only: [:edit, :update]
  before_action :require_approver, only: [:approve, :reject]
  helper_method :approver?

  PER_PAGE_OPTIONS = [20, 50, 100].freeze

  def index
    scope = InternalTransfer.recent
    scope = scope_for_user(scope) unless current_user.admin?
    scope = apply_filters(scope)

    @kpis = {
      waiting: scope.with_overall_status('aguardando_aprovacao').count,
      origin: scope.at_stage(:origin).count,
      on_the_way: scope.at_stage(:on_the_way).count,
      done: scope.with_overall_status('concluida').count
    }
    scope = scope.with_overall_status(params[:status]) if InternalTransfer::STATUS_LABELS.key?(params[:status])
    scope = scope.at_stage(params[:kpi]) if InternalTransfer::STAGE_FILTERS.include?(params[:kpi].to_s)
    scope = only_my_action(scope) if params[:mine] == '1'

    @per_page = PER_PAGE_OPTIONS.include?(params[:per_page].to_i) ? params[:per_page].to_i : PER_PAGE_OPTIONS.first
    @transfers = scope.includes(:destination_location, shipments: [:origin_location, :items]).paginate(page: params[:page], per_page: @per_page)
    @filter_locations = Location.where.not(slug: EXCLUDED_LOCATION_SLUGS).order(:name)
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
    load_approvers
  end

  # A edição também mostra a aprovação, para a transferência ter uma tela só enquanto está aberta,
  # e tem duas abas: Pedido (o formulário) e Nota fiscal (NF-e de cada remessa, homologação e produção).
  def edit
    load_approvers
    prepare_form
    load_fiscal_tab
  end

  def update
    before = approval_signature(@transfer)
    @transfer.assign_attributes(header_params)
    # Salvar sem mudar destino nem itens (só observação, ou nada) não mexe nas remessas nem na aprovação:
    # antes, qualquer "Salvar alterações" devolvia a transferência aprovada para a fila de aprovação.
    items_changed = approval_signature(@transfer, rows: item_rows) != before
    # Mudar os itens recria as remessas, e a nota emitida é da remessa: exclui a nota antes.
    if items_changed && @transfer.shipments.any? { |shipment| shipment.fiscal_notes.exists? }
      @transfer.errors.add(:base, 'Esta transferência já tem nota fiscal emitida. Exclua as notas na aba Nota fiscal antes de mudar a loja de destino ou os itens.')
      load_approvers
      prepare_form
      load_fiscal_tab
      return render :edit, status: :unprocessable_entity
    end
    if items_changed
      @transfer.shipments.each(&:mark_for_destruction)
      build_shipments(@transfer)
    end
    # Mudou o que foi aprovado: precisa de nova aprovação.
    reapproval = @transfer.approval_aprovada? && approval_signature(@transfer) != before
    @transfer.assign_attributes(approval_status: :pendente, reviewed_by: nil, reviewed_at: nil) if reapproval

    if @transfer.save
      log_event(@transfer, action: 'updated', message: 'Transferência editada; volta a aguardar aprovação.') if reapproval
      redirect_to internal_transfer_path(@transfer), notice: reapproval ? 'Transferência atualizada. Ela volta a aguardar aprovação.' : 'Transferência atualizada.'
    else
      load_approvers
      prepare_form
      load_fiscal_tab
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
              InternalTransfer.includes({ destination_location: :company }, :requested_by, events: :user,
                                        shipments: [{ origin_location: :company }, { items: :product }, :fiscal_notes])
            when 'update'
              InternalTransfer.includes(shipments: :items)
            else
              InternalTransfer
            end
    @transfer = scope.find(params[:id])
  end

  # Remessas com empresas e notas para a aba Nota fiscal; `@tab` diz qual aba abre.
  def load_fiscal_tab
    @tab = params[:tab] == 'nota' ? 'nota' : 'pedido'
    shipments = @transfer.shipments.reject(&:marked_for_destruction?).select(&:persisted?)
    ActiveRecord::Associations::Preloader.new(records: shipments, associations: [{ origin_location: :company }, :fiscal_notes]).call
    ActiveRecord::Associations::Preloader.new(records: [@transfer], associations: { destination_location: :company }).call
    @fiscal_shipments = shipments.sort_by { |shipment| shipment.origin_location.name }
  end

  def load_approvers
    @approvers = User.where(id: InternalTransferApprover.user_ids).order(:name)
  end

  def approver?
    @approver_flag = InternalTransferApprover.can_approve?(current_user) if @approver_flag.nil?
    @approver_flag
  end

  def require_approver
    return if approver?

    redirect_to internal_transfer_path(@transfer), alert: 'Só os aprovadores configurados ou um admin podem aprovar ou reprovar transferências.'
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
  # Filtros da lista (menos o status, que vira aba com contagem).
  def apply_filters(scope)
    scope = scope.search(params[:q]) if params[:q].present?
    scope = scope.where(destination_location_id: params[:destination_id]) if params[:destination_id].present?
    scope = scope.with_origin(params[:origin_id]) if params[:origin_id].present?
    scope = scope.where(created_at: parse_date(params[:from]).beginning_of_day..) if parse_date(params[:from])
    scope = scope.where(created_at: ..parse_date(params[:to]).end_of_day) if parse_date(params[:to])
    scope
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # "Aguardando minha ação" depende das permissões do usuário em cada loja: é calculado em Ruby, só
  # sobre as transferências que ainda não terminaram.
  def only_my_action(scope)
    approver_ids = InternalTransferApprover.user_ids
    open_scope = scope.where.not(id: InternalTransfer.with_overall_status('concluida').select(:id))
                      .where.not(id: InternalTransfer.with_overall_status('cancelada').select(:id))
                      .where.not(approval_status: :reprovada)
    transfers = open_scope.to_a
    # Aguardando aprovação só depende de quem é o usuário: lojas e itens só para as já aprovadas.
    approved = transfers.reject(&:approval_pendente?)
    ActiveRecord::Associations::Preloader.new(records: approved, associations: [:destination_location, { shipments: [:origin_location, :items] }]).call
    ids = transfers.select { |transfer| transfer.my_action_needed?(current_user, approver_ids:) }.map(&:id)
    scope.where(id: ids)
  end

  def scope_for_user(scope)
    slugs = current_user.allowed_location_keys
    ids = slugs.flat_map { |slug| InternalTransfer.involving_location_slug(slug).ids }
    ids += InternalTransfer.approval_pendente.ids if approver?
    scope.where(id: ids.uniq)
  end

  # Cada célula da grade (produto x loja de origem) vira um item; célula em branco é ignorada.
  # As linhas são agrupadas por loja de origem em uma remessa por origem.
  def build_shipments(transfer)
    rows = item_rows
    products = Product.where(id: rows.map { |row| row[:product_id] }).index_by(&:id)

    rows.group_by { |row| row[:location_id].to_i }.each do |location_id, group|
      shipment = transfer.shipments.build(origin_location_id: location_id)
      group.each { |row| shipment.items.build(product: products[row[:product_id].to_i], product_id: row[:product_id], quantity: row[:quantity]) }
    end
  end

  # Linhas da grade enviadas no formulário (célula em branco e Correios Log ficam de fora).
  def item_rows
    @item_rows ||= begin
      excluded_ids = Location.where(slug: EXCLUDED_LOCATION_SLUGS).ids
      rows = params.require(:internal_transfer).permit(items: [:product_id, :location_id, :quantity])[:items]
      rows = rows.respond_to?(:values) ? rows.values : Array(rows)
      rows.reject { |row| row[:quantity].blank? || excluded_ids.include?(row[:location_id].to_i) }
    end
  end

  # O que a aprovação cobre: destino e, por loja de origem, produto e quantidade. Com `rows`, usa as
  # linhas do formulário no lugar das remessas atuais.
  def approval_signature(transfer, rows: nil)
    items = if rows
              rows.map { |row| [row[:location_id].to_i, row[:product_id].to_i, row[:quantity].to_i] }
            else
              transfer.shipments.reject(&:marked_for_destruction?).flat_map do |shipment|
                shipment.items.reject(&:marked_for_destruction?).map { |item| [shipment.origin_location_id, item.product_id, item.quantity.to_i] }
              end
            end
    [transfer.destination_location_id, items.sort]
  end

  # As lojas de origem para a grade nunca incluem a loja de destino escolhida (não dá para
  # transferir de uma loja para ela mesma). Se o admin trocar o destino, a lista de origens só
  # atualiza num novo carregamento da página.
  def prepare_form
    @my_locations = (current_user.admin? ? transferable_locations : transferable_locations.where(slug: current_user.allowed_location_keys)).order(:name)
    @origin_locations = transferable_locations.where.not(id: @transfer.destination_location_id).order(:name)
    # Produtos só para desenhar a grade (no redirect de uma edição bloqueada nem carrega).
    ActiveRecord::Associations::Preloader.new(records: @transfer.shipments.to_a, associations: { items: :product }).call
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
