require 'csv'

class B2bOrdersController < ApplicationController
  guard_screen :b2b_orders
  before_action :set_kind
  before_action :set_b2b_order, only: [:edit, :update, :transmit, :cancel_in_tiny]
  helper_method :order_kind, :orders_path_for, :new_order_path_for, :edit_order_path_for, :transmit_order_path_for, :order_form_url

  def index
    scope = B2bOrder.includes(:client, :transfer_location, :b2b_order_items).recent.where(kind: order_kind)

    if params[:q].present?
      q = "%#{params[:q]}%"
      scope = scope.where(
        'clients.responsible_name LIKE :q OR clients.business_name LIKE :q OR b2b_orders.tiny_reference_number LIKE :q OR b2b_orders.id = :id',
        q: q, id: params[:q].to_i
      ).references(:client)
    end

    @status_counts = scope.reorder(nil).group(:status).count
    @b2b_orders = params[:status].present? ? scope.where(status: params[:status]) : scope
  end

  def new
    @b2b_order = B2bOrder.new(kind: order_kind, price_list: price_list_for(order_kind))
  end

  def create
    @b2b_order = B2bOrder.new(b2b_order_params.merge(kind: order_kind, price_list: price_list_for(order_kind)))
    @b2b_order.user = current_user

    if @b2b_order.save
      kind, message = send_to_tiny(@b2b_order, saved: true)
      redirect_to orders_path_for(order_kind), kind => message
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    @b2b_order.assign_attributes(b2b_order_params)
    push_status = @b2b_order.status_changed? && @b2b_order.sale? && @b2b_order.tiny_reference_id.present?

    if @b2b_order.save
      flash_options = { notice: 'Pedido atualizado com sucesso.' }
      if push_status
        result = B2bTinyService.new.update_order_status(@b2b_order.tiny_reference_id, @b2b_order.status)
        flash_options[:alert] = "Status salvo no Honey, mas o Tiny não aceitou a mudança: #{result[:error]}" unless result[:success]
      end
      redirect_to orders_path_for(order_kind), flash_options
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def transmit
    unless @b2b_order.resendable?
      redirect_to orders_path_for(order_kind), alert: 'Este pedido não pode ser reenviado.'
      return
    end

    kind, message = send_to_tiny(@b2b_order)
    redirect_to orders_path_for(order_kind), kind => message
  end

  # A API do Tiny não permite excluir pedido (só alterar a situação). Então cancelamos o pedido lá,
  # desvinculamos do Honey e deixamos o pedido pronto para ser reenviado como um pedido novo.
  # O cancelado continua existindo no Tiny e pode ser excluído manualmente por lá.
  def cancel_in_tiny
    if @b2b_order.tiny_reference_id.blank?
      redirect_to orders_path_for(order_kind), alert: 'Este pedido não foi enviado ao Tiny; não há o que cancelar.'
      return
    end

    number = @b2b_order.tiny_reference_number.presence || @b2b_order.tiny_reference_id
    result = B2bTinyService.new.update_order_status(@b2b_order.tiny_reference_id, 'cancelado')

    if result[:success]
      unlink_from_tiny(@b2b_order, number)
      redirect_to orders_path_for(order_kind),
                  notice: "Pedido nº #{number} cancelado no Tiny. Este pedido foi liberado para reenvio (o cancelado continua no Tiny e pode ser excluído por lá)."
    else
      redirect_to orders_path_for(order_kind), alert: "O Tiny não cancelou o pedido nº #{number}: #{result[:error]}"
    end
  end

  def shipping_methods
    methods = Rails.cache.fetch('tiny2_shipping_methods', expires_in: 10.minutes) do
      B2bTinyService.new.shipping_methods
    end
    render json: { success: true, shipping_methods: methods }
  end

  def parse_items_spreadsheet
    file = params[:file]
    unless file.present?
      render json: { success: false, message: 'Nenhum arquivo enviado.' }
      return
    end

    csv = CSV.parse(file.read.force_encoding('UTF-8'), headers: true)
    items = csv.filter_map do |row|
      sku = row['SKU']
      quantity = row['Quantidade'].to_i
      next if sku.blank? || quantity <= 0

      product = Product.find_by(sku: sku)
      { sku: sku, name: product&.shopify_product_name, quantity: quantity,
        suggested_price: suggested_price_for(product),
        retail_price: product&.price.to_f,
        image_url: product ? image_url_for(product) : nil }
    end

    if items.empty?
      render json: { success: false, message: 'Nenhum item válido encontrado na planilha (colunas esperadas: SKU, Quantidade).' }
    else
      render json: { success: true, items: items }
    end
  rescue StandardError => e
    render json: { success: false, message: "Erro ao processar planilha: #{e.message}" }
  end

  def product_stock
    sku = params[:sku]
    product = Product.find_by(sku: sku)

    unless product
      render json: { success: true, quantity: 0, status: 'error', message: 'Produto não encontrado' }
      return
    end

    render json: { success: true, **correios_stock_for(product) }
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = token_search(query).limit(10)

    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, image_url: image_url_for(p), suggested_price: suggested_price_for(p), retail_price: p.price.to_f } } }
  end

  # Modal "Selecionar Produtos" (estilo Shopify): agrupa os SKUs encontrados
  # pelo nome do produto, cada grupo vira "produto" com suas variantes (SKUs).
  def product_picker
    query = params[:query].to_s.strip
    products = query.present? ? token_search(query).limit(300) : Product.order(:shopify_product_name).limit(60)

    grouped = products.group_by { |p| p.shopify_product_name.presence || p.sku }.first(40)

    result = grouped.map do |name, variants|
      {
        name: name,
        image_url: variants.find { |v| v.image_url.present? }&.image_url,
        variants: variants.map do |v|
          {
            id: v.id,
            sku: v.sku,
            option: v.option1.presence || v.sku,
            price: suggested_price_for(v),
            retail_price: v.price.to_f
          }
        end
      }
    end

    render json: { success: true, products: result }
  end

  def search_client
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    local_clients = Client.where(
      'LOWER(responsible_name) LIKE :q OR LOWER(business_name) LIKE :q OR registration LIKE :q',
      q: "%#{query.downcase}%"
    ).limit(10)

    local_registrations = local_clients.filter_map { |c| c.registration.to_s.gsub(/\D/, '').presence }

    local_results = local_clients.map do |c|
      { source: 'honey', client_id: c.id, name: c.display_name, registration: c.cnpj_formatted }
    end

    tiny_results = B2bTinyService.new.search_clients(query).filter_map do |c|
      digits = c[:registration].to_s.gsub(/\D/, '')
      next if digits.present? && local_registrations.include?(digits)

      {
        source: 'tiny', tiny_id: c[:tiny_id], name: c[:name], registration: c[:registration],
        street: c[:street], number: c[:number], complement: c[:complement],
        neighbourhood: c[:neighbourhood], city: c[:city], state: c[:state], zip: c[:zip],
        email: c[:email], phone: c[:phone]
      }
    end.first(10)

    render json: { success: true, clients: local_results + tiny_results }
  end

  def import_client
    registration = params[:registration].to_s.gsub(/\D/, '')

    client = if registration.present?
               Client.where(
                 "REPLACE(REPLACE(REPLACE(registration, '.', ''), '/', ''), '-', '') = ?",
                 registration
               ).first
             end
    client ||= Client.new(
      responsible_name: params[:name],
      registration: registration.presence,
      street: params[:street],
      number: params[:number],
      neighbourhood: params[:neighbourhood],
      city: params[:city],
      state: params[:state],
      zip: params[:zip],
      email: params[:email],
      phone: params[:phone]
    )

    if client.persisted? || client.save
      render json: { success: true, client: { id: client.id, display_name: client.display_name, registration: client.cnpj_formatted } }
    else
      render json: { success: false, errors: client.errors.full_messages }
    end
  end

  private

  # Busca "inteligente": cada palavra da query precisa aparecer em algum lugar
  # do SKU ou do nome, em qualquer ordem — assim "signature black" encontra
  # "Legging Signature Seamless Black", "Short Signature Black" etc.
  def token_search(query)
    tokens = query.to_s.downcase.split(/\s+/).reject(&:blank?)
    return Product.none if tokens.empty?

    tokens.reduce(Product.all) do |scope, token|
      scope.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{token}%")
    end
  end

  def suggested_price_for(product)
    return nil unless product&.price.present?

    (product.price.to_f * 0.4).round(2)
  end

  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil unless product.shopify_product_id.present?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url
  end

  def correios_stock_for(product)
    response = Correios::Orders.get_stock(product.sku, from_tiny2: true)
    return { quantity: 0, status: 'error' } unless response.respond_to?(:success?) && response.success?

    quantity = JSON.parse(response.body)['disponivel'].to_i
    status = quantity > 10 ? 'high' : (quantity.positive? ? 'low' : 'out')
    { quantity: quantity, status: status }
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#correios_stock_for exception: #{e.message}"
    { quantity: 0, status: 'error' }
  end

  # O envio ao Tiny é SEMPRE síncrono (perform_now): o resultado aparece na hora, sem depender de
  # fila/worker, e o pedido não fica preso atrás de outros jobs. Devolve [tipo_do_flash, mensagem].
  def send_to_tiny(order, saved: false)
    TransmitB2bOrderJob.perform_now(order.id)
    order.reload
    label = order.stock_transfer? ? 'Transferência' : 'Pedido'

    if order.tiny_reference_id.present?
      number = order.tiny_reference_number.presence || order.tiny_reference_id
      [:notice, "#{label} #{saved ? 'salvo e ' : ''}enviado ao Tiny (nº #{number})."]
    else
      [:alert, "#{label} #{saved ? 'salvo, mas o' : 'não enviado: o'} Tiny não aceitou: #{order.error_message.presence || 'motivo não informado'}"]
    end
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#send_to_tiny (#{order.id}): #{e.class} #{e.message}"
    order.reload.update_columns(status: B2bOrder.statuses[:dados_incompletos], error_message: e.message.to_s.first(255)) unless order.tiny_reference_id.present?
    [:alert, "#{order.stock_transfer? ? 'Transferência' : 'Pedido'} #{saved ? 'salvo, mas não' : 'não'} enviado ao Tiny: #{e.message}"]
  end

  def unlink_from_tiny(order, number)
    tiny_id = order.tiny_reference_id
    order.update!(tiny_reference_id: nil, tiny_reference_number: nil, status: :aberto, error_message: nil)
    LogService.create_log(
      user: current_user, resource_type: 'b2b_order', action_type: 'cancel_in_tiny',
      resource_name: "Pedido B2B ##{order.id}", resource_id: order.id,
      details: { tiny_reference_id: tiny_id, tiny_reference_number: number }, request: request
    )
  end

  def set_kind
    @order_kind = params[:order_kind]
  end

  def order_kind
    @order_kind
  end

  # Atacado usa sempre a lista Padrão; a lista Transferência só existe na tela de transferência.
  def price_list_for(kind)
    kind.to_s == 'stock_transfer' ? :transfer : :standard
  end

  def stock_transfer_screen?(kind = order_kind)
    kind.to_s == 'stock_transfer'
  end

  def orders_path_for(kind = order_kind)
    stock_transfer_screen?(kind) ? stock_transfers_path : b2b_orders_path
  end

  def new_order_path_for(kind = order_kind)
    stock_transfer_screen?(kind) ? new_stock_transfer_path : new_b2b_order_path
  end

  def edit_order_path_for(order)
    stock_transfer_screen?(order.kind) ? edit_stock_transfer_path(order) : edit_b2b_order_path(order)
  end

  def transmit_order_path_for(order)
    stock_transfer_screen?(order.kind) ? transmit_stock_transfer_path(order) : transmit_b2b_order_path(order)
  end

  def order_form_url(order)
    if stock_transfer_screen?(order.kind)
      order.persisted? ? stock_transfer_path(order) : stock_transfers_path
    else
      order.persisted? ? b2b_order_path(order) : b2b_orders_path
    end
  end

  def set_b2b_order
    @b2b_order = B2bOrder.where(kind: order_kind).find(params[:id])
  end

  def b2b_order_params
    params.require(:b2b_order).permit(
      :client_id, :transfer_location_id, :carrier_id, :carrier_name,
      :carrier_shipping_method, :freight_service, :freight_paid_by, :freight_value, :notes,
      :salesperson_name, :status, :different_shipping_address,
      :shipping_street, :shipping_number, :shipping_complement, :shipping_neighbourhood,
      :shipping_city, :shipping_state, :shipping_zip,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :discount, :_destroy]
    )
  end
end
