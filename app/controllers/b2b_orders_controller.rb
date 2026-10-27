require 'csv'

class B2bOrdersController < ApplicationController
  guard_screen :b2b_orders
  before_action :set_kind
  before_action :set_b2b_order, only: [:edit, :update, :transmit, :cancel_in_tiny, :destroy, :romaneio, :danfe, :send_danfe]
  helper_method :order_kind, :order_deletable?, :orders_path_for, :new_order_path_for, :edit_order_path_for, :transmit_order_path_for,
                :order_path_for, :cancel_in_tiny_order_path_for, :romaneio_order_path_for, :order_form_url

  # Cada tipo de pedido tem a sua tela (rota) e o nome usado nas mensagens.
  ROUTE_KEYS = { 'sale' => 'b2b_order', 'stock_transfer' => 'stock_transfer', 'b2c_transfer' => 'b2c_transfer' }.freeze
  KIND_LABELS = { 'sale' => 'Pedido', 'stock_transfer' => 'Abastecimento', 'b2c_transfer' => 'Transferência B2C' }.freeze

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
    @order_ids_with_active_note = FiscalNote.active_statuses.where(b2b_order_id: @b2b_orders.map(&:id)).pluck(:b2b_order_id).to_set
  end

  def new
    @b2b_order = B2bOrder.new(kind: order_kind, price_list: price_list_for(order_kind))
    prefill_from_catalog_order(@b2b_order) if order_kind == 'sale' && params[:catalog_order_id].present?
  end

  def create
    @b2b_order = B2bOrder.new(b2b_order_params.merge(kind: order_kind, price_list: price_list_for(order_kind)))
    @b2b_order.user = current_user

    if @b2b_order.valid? && stock_available?(@b2b_order) && @b2b_order.save
      link_catalog_order(@b2b_order)
      # O pedido de venda fica só no Honey até alguém clicar em "Enviar ao Tiny".
      if @b2b_order.sale?
        redirect_to orders_path_for(order_kind), notice: "Pedido ##{@b2b_order.id} salvo. Use \"Enviar ao Tiny\" quando estiver pronto."
      else
        kind, message = send_to_tiny(@b2b_order, saved: true, generate_invoice: generate_invoice?)
        redirect_to orders_path_for(order_kind), kind => message
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    @b2b_order.assign_attributes(b2b_order_params)
    push_status = @b2b_order.status_changed? && @b2b_order.tiny_order? && @b2b_order.tiny_reference_id.present?

    if @b2b_order.valid? && stock_available?(@b2b_order) && @b2b_order.save
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

    unless stock_available?(@b2b_order)
      redirect_to orders_path_for(order_kind), alert: @b2b_order.errors.full_messages.to_sentence
      return
    end

    kind, message = send_to_tiny(@b2b_order, generate_invoice: generate_invoice?)
    redirect_to orders_path_for(order_kind), kind => message
  end

  # Exclui o pedido do Honey. Se ele já está no Tiny, cancela lá primeiro (a API do Tiny não exclui
  # pedido; o cancelado pode ser excluído manualmente por lá). Pedido com nota fiscal ativa não é excluído.
  def destroy
    unless @b2b_order.deletable?
      redirect_to orders_path_for(order_kind), alert: undeletable_message(@b2b_order)
      return
    end

    if @b2b_order.tiny_reference_id.present?
      number = @b2b_order.tiny_reference_number.presence || @b2b_order.tiny_reference_id
      outcome, error = cancel_order_in_tiny(@b2b_order)
      if outcome == :error
        redirect_to orders_path_for(order_kind), alert: "O Tiny não cancelou o pedido nº #{number}, então ele não foi excluído: #{error}"
        return
      end
    end

    snapshot = { kind: @b2b_order.kind, status: @b2b_order.status, total: @b2b_order.total.to_f, items: @b2b_order.b2b_order_items.size,
                 client: @b2b_order.client&.display_name, transfer_location: @b2b_order.transfer_location&.name,
                 tiny_reference_id: @b2b_order.tiny_reference_id, tiny_reference_number: @b2b_order.tiny_reference_number }.compact
    id = @b2b_order.id
    @b2b_order.destroy!
    LogService.create_log(user: current_user, resource_type: 'b2b_order', action_type: 'delete',
                          resource_name: "Pedido B2B ##{id}", resource_id: id, details: snapshot, request: request)
    tiny_note = outcome == :missing ? " (o nº #{number} já não existia no Tiny)" : " (cancelado no Tiny, nº #{number})" if number
    redirect_to orders_path_for(order_kind), notice: "Pedido ##{id} excluído#{tiny_note}."
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
    outcome, error = cancel_order_in_tiny(@b2b_order)

    case outcome
    when :cancelled
      unlink_from_tiny(@b2b_order, number)
      redirect_to orders_path_for(order_kind),
                  notice: "Pedido nº #{number} cancelado no Tiny. Este pedido foi liberado para reenvio (o cancelado continua no Tiny e pode ser excluído por lá)."
    when :missing
      unlink_from_tiny(@b2b_order, number, missing: true)
      redirect_to orders_path_for(order_kind),
                  notice: "O pedido nº #{number} não existe mais no Tiny. O vínculo foi removido e este pedido foi liberado para reenvio."
    else
      redirect_to orders_path_for(order_kind), alert: "O Tiny não cancelou o pedido nº #{number}: #{error}"
    end
  end

  # Romaneio em PDF (lista de itens) para mandar ao cliente; o navegador já baixa o arquivo.
  def romaneio
    pdf = B2bRomaneioPdf.new(@b2b_order)
    send_data pdf.render, filename: pdf.filename, type: 'application/pdf', disposition: 'attachment'
  end

  # DANFE do abastecimento em PDF. O Tiny só entrega o DANFE como página HTML, que é convertida aqui.
  def danfe
    result = B2bTinyService.new.danfe_link(@b2b_order.tiny_reference_id)
    unless result[:success]
      redirect_to orders_path_for(order_kind), alert: "DANFE do abastecimento ##{@b2b_order.id} indisponível: #{result[:error]}"
      return
    end

    pdf = WickedPdf.new.pdf_from_url(result[:url], page_size: 'A4')
    send_data pdf, filename: "DANFE-#{result[:number].presence || @b2b_order.tiny_reference_number}.pdf",
                   type: 'application/pdf', disposition: 'attachment'
  end

  # Envia o DANFE por e-mail (um ou mais endereços, separados por vírgula). A nota é conferida aqui,
  # para o erro aparecer na hora; o PDF é gerado e enviado em segundo plano.
  def send_danfe
    emails = params[:emails].to_s.split(/[,;\s]+/).map(&:strip).reject(&:blank?).uniq
    invalid = emails.reject { |email| email.match?(URI::MailTo::EMAIL_REGEXP) }
    if emails.empty? || invalid.any?
      redirect_to orders_path_for(order_kind), alert: "Informe e-mail(s) válido(s) para enviar a nota#{": #{invalid.join(', ')}" if invalid.any?}."
      return
    end

    result = B2bTinyService.new.danfe_link(@b2b_order.tiny_reference_id)
    unless result[:success]
      redirect_to orders_path_for(order_kind), alert: "Nota do abastecimento ##{@b2b_order.id} não enviada: #{result[:error]}"
      return
    end

    InvoiceMailer.with(order_id: @b2b_order.id, to: emails, danfe_url: result[:url], number: result[:number],
                       sender_name: current_user.name).stock_transfer_danfe.deliver_later
    redirect_to orders_path_for(order_kind), notice: "Nota nº #{result[:number]} sendo enviada para #{emails.join(', ')}."
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

    content = file.read.force_encoding('UTF-8').delete_prefix("\uFEFF")
    # Excel em português salva CSV com ";" no lugar de ",".
    col_sep = content.lines.first.to_s.count(';') > content.lines.first.to_s.count(',') ? ';' : ','
    csv = CSV.parse(content, headers: true, col_sep: col_sep)
    items = csv.filter_map do |row|
      sku = row['SKU']&.strip
      quantity = row['Quantidade'].to_i
      next if sku.blank? || quantity <= 0

      product = Product.find_by(sku: sku)
      { sku: sku, name: product&.shopify_product_name, quantity: quantity,
        suggested_price: suggested_price_for(product),
        retail_price: product&.price.to_f,
        b2c_transfer_price: b2c_transfer_price_for(product),
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

    own_tiny_order_id = B2bOrder.find_by(id: params[:b2b_order_id])&.tiny_reference_id
    result = B2bStockAvailability.for_sku(product.sku, exclude_tiny_order_id: own_tiny_order_id)
    render json: { success: true, quantity: result.available, stock: result.stock, reserved: result.reserved, status: result.status }
  end

  def search_product
    query = params[:query].to_s.strip
    if query.blank?
      render json: { success: false, message: 'Query não fornecida' }
      return
    end

    products = token_search(query).limit(10)

    render json: { success: true, products: products.map { |p| { id: p.id, sku: p.sku, name: p.shopify_product_name, image_url: image_url_for(p), suggested_price: suggested_price_for(p), retail_price: p.price.to_f, b2c_transfer_price: b2c_transfer_price_for(p) } } }
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
            retail_price: v.price.to_f,
            b2c_transfer_price: b2c_transfer_price_for(v)
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

  # A transferência B2B -> B2C sai por 70% do custo do produto.
  def b2c_transfer_price_for(product)
    return nil unless product&.cost.to_f.positive?

    (product.cost.to_f * 0.7).round(2)
  end

  def image_url_for(product)
    return product.image_url if product.image_url.present?

    Shopify::Products.update_product_with_shopify_id(product) if product.shopify_product_id.blank?
    return nil unless product.shopify_product_id.present?

    Shopify::Products.update_product_with_image_url(product)
    product.image_url
  end

  # Pedido de venda a partir de uma encomenda de catálogo: itens, quantidades, cliente (pelo CNPJ) e
  # preço sugerido de sempre. O usuário completa o resto e salva.
  def prefill_from_catalog_order(order)
    catalog_order = B2bCatalogOrder.includes(:catalog, items: { variant: :catalog_product }).find_by(id: params[:catalog_order_id])
    return unless catalog_order && !catalog_order.converted?

    order.client = catalog_order.matching_client
    order.notes = "Encomenda do catálogo \"#{catalog_order.catalog.title}\" — #{catalog_order.customer_name}"
    products = Product.where(sku: catalog_order.items.map { |item| item.variant.sku }).index_by { |p| p.sku.to_s.upcase }

    catalog_order.items.sort_by { |item| [item.variant.catalog_product.position, item.variant.position] }.each do |item|
      variant = item.variant
      product = products[variant.sku]
      name = product&.shopify_product_name.present? ? "#{product.shopify_product_name} - #{variant.size}" : "#{variant.catalog_product.style_name} #{variant.catalog_product.color_name} #{variant.size}".squish
      order.b2b_order_items.build(sku: variant.sku, name:, quantity: item.quantity, price: suggested_price_for(product) || 0)
    end
  end

  def link_catalog_order(order)
    return if params[:catalog_order_id].blank?

    B2bCatalogOrder.find_by(id: params[:catalog_order_id])&.convert!(order)
  end

  # Bloqueia itens acima do disponível no Correios B2B (estoque − reservas da fila do Tiny2). Só vale
  # enquanto o pedido não chegou ao Tiny: depois disso os itens dele já estão na própria reserva.
  def stock_available?(order)
    return true if order.tiny_reference_id.present? || order.cancelado?

    shortages = B2bStockAvailability.shortages(order.b2b_order_items)
    shortages.each do |s|
      order.errors.add(:base, "#{s[:sku]}: pedido #{s[:requested]}, disponível #{s[:available]} " \
                              "(estoque #{s[:stock]}, #{s[:reserved]} reservados na fila)")
    end
    shortages.empty?
  end

  # O envio ao Tiny é SEMPRE síncrono (perform_now): o resultado aparece na hora, sem depender de
  # fila/worker, e o pedido não fica preso atrás de outros jobs. Devolve [tipo_do_flash, mensagem].
  def send_to_tiny(order, saved: false, generate_invoice: false)
    TransmitB2bOrderJob.perform_now(order.id)
    order.reload
    label = KIND_LABELS[order.kind]

    if order.tiny_reference_id.present?
      number = order.tiny_reference_number.presence || order.tiny_reference_id
      message = "#{label} #{saved ? 'salvo e ' : ''}enviado ao Tiny (nº #{number})."
      return [:notice, message] unless generate_invoice && order.tiny_order?

      invoice = B2bTinyService.new.generate_invoice(order.tiny_reference_id)
      if invoice[:success] && order.stock_transfer?
        emit_stock_transfer_invoice(message, invoice)
      elsif invoice[:success]
        [:notice, "#{message} Nota fiscal gerada no Tiny#{" (nº #{invoice[:number]})" if invoice[:number]}, falta emitir por lá."]
      else
        [:alert, "#{message} Mas o Tiny não gerou a nota fiscal: #{invoice[:error]}. Gere a nota pelo Tiny."]
      end
    else
      [:alert, "#{label} #{saved ? 'salvo, mas o' : 'não enviado: o'} Tiny não aceitou: #{order.error_message.presence || 'motivo não informado'}"]
    end
  rescue StandardError => e
    Rails.logger.error "B2bOrdersController#send_to_tiny (#{order.id}): #{e.class} #{e.message}"
    order.reload.update_columns(status: B2bOrder.statuses[:dados_incompletos], error_message: e.message.to_s.first(255)) unless order.tiny_reference_id.present?
    [:alert, "#{KIND_LABELS[order.kind]} #{saved ? 'salvo, mas não' : 'não'} enviado ao Tiny: #{e.message}"]
  end

  # O abastecimento já sai com a nota emitida, para o DANFE ficar disponível na lista. A autorização da
  # SEFAZ leva alguns segundos; se a emissão falhar aqui, a fila de emissão do Correios B2B tenta de novo.
  def emit_stock_transfer_invoice(message, invoice)
    number = " (nº #{invoice[:number]})" if invoice[:number]
    emission = B2bTinyService.new.emit_invoice(invoice[:invoice_id])
    if emission[:success]
      [:notice, "#{message} Nota fiscal#{number} emitida no Tiny. O DANFE fica disponível na lista assim que a SEFAZ autorizar."]
    else
      [:alert, "#{message} Nota fiscal#{number} gerada, mas o Tiny não emitiu: #{emission[:error]}. Emita pelo Tiny."]
    end
  end

  # Checkbox "Gerar nota fiscal no Tiny" do envio do atacado. Abastecimento e transferência B2C sempre vão
  # com a nota gerada (os Correios B2B precisam dela na fila de preparando envio).
  def generate_invoice?
    order_kind != 'sale' || params[:generate_invoice] == '1'
  end

  def undeletable_message(order)
    if order.tiny_reference_id.present? && !order.tiny_order?
      number = order.tiny_reference_number.presence || order.tiny_reference_id
      "Este abastecimento já virou nota fiscal no Tiny (nº #{number}) e não pode ser excluído."
    else
      'Este pedido tem uma nota fiscal ativa e não pode ser excluído.'
    end
  end

  # Cancela o pedido no Tiny. Se o Tiny recusar, confere se o pedido ainda existe lá: pedido que
  # foi excluído pelo Tiny não tem o que cancelar, só o vínculo a remover. Devolve [:cancelled | :missing | :error, erro].
  def cancel_order_in_tiny(order)
    service = B2bTinyService.new
    result = service.update_order_status(order.tiny_reference_id, 'cancelado')
    return [:cancelled, nil] if result[:success]
    return [:missing, nil] if service.order_missing?(order.tiny_reference_id)

    [:error, result[:error]]
  end

  def unlink_from_tiny(order, number, missing: false)
    tiny_id = order.tiny_reference_id
    order.update!(tiny_reference_id: nil, tiny_reference_number: nil, status: :aberto, error_message: nil)
    LogService.create_log(
      user: current_user, resource_type: 'b2b_order', action_type: 'cancel_in_tiny',
      resource_name: "Pedido B2B ##{order.id}", resource_id: order.id,
      details: { tiny_reference_id: tiny_id, tiny_reference_number: number, missing_in_tiny: missing || nil }.compact, request: request
    )
  end

  def set_kind
    @order_kind = params[:order_kind]
  end

  def order_kind
    @order_kind
  end

  # Atacado usa sempre a lista Padrão; a lista Transferência só existe nas telas de transferência.
  def price_list_for(kind)
    kind.to_s == 'sale' ? :standard : :transfer
  end

  # Na lista usa o conjunto de pedidos com nota ativa (uma consulta só) em vez de consultar por pedido.
  def order_deletable?(order)
    return order.deletable? unless @order_ids_with_active_note

    (order.tiny_reference_id.blank? || order.tiny_order?) && !@order_ids_with_active_note.include?(order.id)
  end

  def route_key(kind)
    ROUTE_KEYS.fetch(kind.to_s)
  end

  def orders_path_for(kind = order_kind)
    public_send("#{route_key(kind).pluralize}_path")
  end

  def new_order_path_for(kind = order_kind)
    public_send("new_#{route_key(kind)}_path")
  end

  def order_path_for(order)
    public_send("#{route_key(order.kind)}_path", order)
  end

  def edit_order_path_for(order)
    public_send("edit_#{route_key(order.kind)}_path", order)
  end

  def transmit_order_path_for(order)
    public_send("transmit_#{route_key(order.kind)}_path", order)
  end

  def cancel_in_tiny_order_path_for(order)
    public_send("cancel_in_tiny_#{route_key(order.kind)}_path", order)
  end

  def romaneio_order_path_for(order)
    public_send("romaneio_#{route_key(order.kind)}_path", order)
  end

  def order_form_url(order)
    order.persisted? ? order_path_for(order) : orders_path_for(order.kind)
  end

  def set_b2b_order
    @b2b_order = B2bOrder.where(kind: order_kind).find(params[:id])
  end

  # As transferências não aceitam dados de envio: a B2C tem destinatário fixo e vai como transportadora; o
  # abastecimento vai sempre por SEDEX com mão própria. Só o abastecimento escolhe o local de destino e o
  # responsável pelo recebimento.
  SHIPPING_PARAMS = %i[client_id carrier_id carrier_name carrier_shipping_method freight_service].freeze

  def b2b_order_params
    permitted = b2b_order_permitted_params
    case order_kind
    when 'b2c_transfer' then permitted.except(*SHIPPING_PARAMS, :transfer_location_id, :receiver_name)
    when 'stock_transfer' then permitted.except(*SHIPPING_PARAMS)
    else permitted.except(:receiver_name)
    end
  end

  def b2b_order_permitted_params
    params.require(:b2b_order).permit(
      :client_id, :transfer_location_id, :carrier_id, :carrier_name,
      :carrier_shipping_method, :freight_service, :freight_paid_by, :freight_value, :notes,
      :salesperson_name, :receiver_name, :status, :different_shipping_address,
      :shipping_street, :shipping_number, :shipping_complement, :shipping_neighbourhood,
      :shipping_city, :shipping_state, :shipping_zip,
      b2b_order_items_attributes: [:id, :sku, :name, :quantity, :price, :discount, :_destroy]
    )
  end
end
