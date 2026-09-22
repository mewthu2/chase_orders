# Recebe uma remessa (já enviada): credita no Shopify, na loja de destino, a quantidade de
# cada item reservado (ajuste de inventário lançado no histórico do inventário). Síncrono e
# sem fila. Só processa itens ainda reservados (não credita um item já recebido de novo).
class InternalTransferReceiptProcessor
  class Error < StandardError; end

  SHOPIFY_REASON = 'correction'.freeze
  Summary = Struct.new(:received, :failed, keyword_init: true)

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
    todo = @shipment.items.includes(:product).where(status: :reserved).to_a
    process(todo) if todo.any?
    finish!
  end

  private

  def start!
    @shipment.with_lock do
      raise Error, 'Esta remessa não pode ser recebida agora.' unless @shipment.receivable?
    end
  end

  def process(items)
    shopify_location_id = @shipment.internal_transfer.destination_location.shopify_location_id.presence
    return fail_all(items, "Location #{@shipment.internal_transfer.destination_location.name} sem ID do Shopify") unless shopify_location_id

    result = adjust(shopify_location_id, items)
    if result[:success]
      items.each { |item| mark_received(item, result[:adjustment_id]) }
    else
      items.each do |item|
        single = adjust(shopify_location_id, [item])
        single[:success] ? mark_received(item, single[:adjustment_id]) : fail_line(item, single[:error])
      end
    end
  rescue StandardError => e
    Rails.logger.error "InternalTransferReceiptProcessor (remessa #{@shipment.id}): #{e.class} #{e.message}"
    fail_all(items.reject(&:received?), "Erro ao ajustar no Shopify: #{e.message}")
  end

  def adjust(shopify_location_id, items)
    @inventory.adjust_available(
      location_id: shopify_location_id,
      changes: items.map { |item| { inventory_item_id: item.product.shopify_inventory_item_id, delta: item.quantity } },
      reason: SHOPIFY_REASON,
      reference_uri: "honey://internal-transfer/#{@shipment.internal_transfer_id}/shipment/#{@shipment.id}?motivo=recebimento"
    )
  end

  def mark_received(item, adjustment_id)
    item.update!(status: :received, error_message: nil, receive_adjustment_id: adjustment_id, received_at: Time.current)
    column = "stock_#{@shipment.internal_transfer.destination_location.slug}"
    product = item.product.reload
    product.update(column => product[column].to_i + item.quantity) if product.respond_to?(column)
  end

  def fail_line(item, message)
    item.update!(error_message: message.to_s.first(500)) # a linha continua "reserved": pode tentar de novo
  end

  def fail_all(items, message)
    items.each { |item| fail_line(item, message) }
  end

  def finish!
    items = @shipment.items.reload
    @shipment.update!(status: :recebido, received_at: Time.current, received_by: @user) if items.all? { |item| item.received? || item.cancelled? }
    received = items.count(&:received?)
    failed = items.count(&:reserved?)
    log_event(received, failed)
    Summary.new(received: received, failed: failed)
  end

  def log_event(received, failed)
    message = "#{received} item(ns) recebido(s)#{", #{failed} com falha" if failed.positive?}."
    InternalTransferEvent.create!(internal_transfer: @shipment.internal_transfer, internal_transfer_shipment: @shipment,
                                  user: @user, action: 'received', message: message)
  end
end
