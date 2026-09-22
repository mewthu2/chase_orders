# Reserva uma remessa de transferência interna: debita a quantidade de cada item no Shopify,
# na loja de origem (ajuste de inventário lançado no histórico do inventário) e marca os itens
# como reservados. Síncrono e sem fila: o resultado está na tela assim que a requisição termina.
#
# - Uma chamada ao Shopify para a remessa inteira; se o grupo for recusado, cada linha é
#   tentada sozinha, para que as boas passem e só as ruins falhem.
# - Linha acima do disponível não é reservada (falha com mensagem).
# - Idempotente: só processa itens pendentes ou com falha; item já reservado nunca é debitado de novo.
class InternalTransferReservationProcessor
  class Error < StandardError; end

  SHOPIFY_REASON = 'correction'.freeze
  Summary = Struct.new(:reserved, :failed, keyword_init: true)

  def self.call(shipment, user:)
    new(shipment, user: user).call
  end

  def initialize(shipment, user:)
    @shipment = shipment
    @user = user
    @inventory = ShopifyInventoryService.new
  end

  def call
    start!
    todo = @shipment.items.includes(:product).where(status: [:pending, :failed]).to_a
    process(todo) if todo.any?
    finish!
  end

  private

  def start!
    @shipment.with_lock do
      raise Error, 'Esta remessa não pode ser reservada agora.' unless @shipment.reservable?
    end
  end

  def process(items)
    shopify_location_id = @shipment.origin_location.shopify_location_id.presence
    return fail_all(items, "Location #{@shipment.origin_location.name} sem ID do Shopify") unless shopify_location_id

    available = @inventory.available_quantities(shopify_location_id, items.map { |item| item.product.shopify_inventory_item_id })
    ready = items.select { |item| check_line(item, available) }
    reserve(shopify_location_id, ready) if ready.any?
  rescue StandardError => e
    Rails.logger.error "InternalTransferReservationProcessor (remessa #{@shipment.id}): #{e.class} #{e.message}"
    fail_all(items.reject(&:reserved?), "Erro ao consultar o Shopify: #{e.message}")
  end

  def check_line(item, available)
    key = item.product.shopify_inventory_item_id.to_s
    return fail_line(item, 'Produto não encontrado nesta location do Shopify') && false unless available.key?(key)

    quantity = available[key]
    return fail_line(item, 'Produto não rastreado nesta location do Shopify') && false if quantity.nil?
    return fail_line(item, "Estoque insuficiente: disponível #{quantity}, retirada #{item.quantity}") && false if item.quantity > quantity

    item.available_before = quantity
    true
  end

  def reserve(shopify_location_id, items)
    result = adjust(shopify_location_id, items)
    if result[:success]
      items.each { |item| mark_reserved(item, result[:adjustment_id]) }
    else
      items.each do |item|
        single = adjust(shopify_location_id, [item])
        single[:success] ? mark_reserved(item, single[:adjustment_id]) : fail_line(item, single[:error])
      end
    end
  end

  def adjust(shopify_location_id, items)
    @inventory.adjust_available(
      location_id: shopify_location_id,
      changes: items.map { |item| { inventory_item_id: item.product.shopify_inventory_item_id, delta: -item.quantity } },
      reason: SHOPIFY_REASON,
      reference_uri: "honey://internal-transfer/#{@shipment.internal_transfer_id}/shipment/#{@shipment.id}?motivo=reserva"
    )
  end

  def mark_reserved(item, adjustment_id)
    item.update!(status: :reserved, error_message: nil, reserve_adjustment_id: adjustment_id, reserved_at: Time.current)
    column = "stock_#{@shipment.origin_location.slug}"
    product = item.product.reload
    product.update(column => product[column].to_i - item.quantity) if product.respond_to?(column)
  end

  def fail_line(item, message)
    item.update!(status: :failed, error_message: message.to_s.first(500))
    true
  end

  def fail_all(items, message)
    items.each { |item| fail_line(item, message) }
  end

  def finish!
    items = @shipment.items.reload
    if items.all?(&:reserved?)
      @shipment.update!(status: :reservado, reserved_at: Time.current, reserved_by: @user)
    end
    reserved = items.count(&:reserved?)
    failed = items.count { |item| item.failed? || item.pending? }
    log_event(reserved, failed)
    Summary.new(reserved: reserved, failed: failed)
  end

  def log_event(reserved, failed)
    action = reserved.positive? ? 'reserved' : 'reservation_failed'
    message = "#{reserved} item(ns) reservado(s)#{", #{failed} com falha" if failed.positive?}."
    InternalTransferEvent.create!(internal_transfer: @shipment.internal_transfer, internal_transfer_shipment: @shipment,
                                  user: @user, action: action, message: message)
  end
end
