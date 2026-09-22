# Cancela uma remessa de transferência interna. Se algum item já tinha sido reservado (debitado
# na origem), devolve a quantidade no Shopify (ajuste de inventário, lançado no histórico do
# inventário) antes de marcar a remessa como cancelada. Itens ainda pendentes ou com falha são
# só marcados como cancelados, sem nenhuma chamada ao Shopify.
class InternalTransferCancellationProcessor
  class Error < StandardError; end

  SHOPIFY_REASON = 'correction'.freeze

  def self.call(shipment, user:)
    new(shipment, user: user).call
  end

  def initialize(shipment, user:)
    @shipment = shipment
    @user = user
    @inventory = ShopifyInventoryService.new
  end

  def call
    @shipment.with_lock do
      raise Error, 'Esta remessa não pode ser cancelada agora.' unless @shipment.cancellable?

      return_reserved_stock if @shipment.returns_stock_on_cancel?
      cancel_remaining_items
      @shipment.update!(status: :cancelado, cancelled_at: Time.current, cancelled_by: @user)
    end
    log_event
    @shipment
  end

  private

  def return_reserved_stock
    reserved_items = @shipment.items.includes(:product).where(status: :reserved).to_a
    return if reserved_items.empty?

    shopify_location_id = @shipment.origin_location.shopify_location_id.presence
    raise Error, "Location #{@shipment.origin_location.name} sem ID do Shopify" unless shopify_location_id

    result = @inventory.adjust_available(
      location_id: shopify_location_id,
      changes: reserved_items.map { |item| { inventory_item_id: item.product.shopify_inventory_item_id, delta: item.quantity } },
      reason: SHOPIFY_REASON,
      reference_uri: "honey://internal-transfer/#{@shipment.internal_transfer_id}/shipment/#{@shipment.id}?motivo=cancelamento"
    )
    raise Error, "O Shopify não aceitou a devolução do estoque: #{result[:error]}" unless result[:success]

    reserved_items.each { |item| restore_item(item, result[:adjustment_id]) }
  end

  def restore_item(item, adjustment_id)
    item.update!(status: :cancelled, cancelled_at: Time.current, reserve_adjustment_id: adjustment_id)
    column = "stock_#{@shipment.origin_location.slug}"
    product = item.product.reload
    product.update(column => product[column].to_i + item.quantity) if product.respond_to?(column)
  end

  def cancel_remaining_items
    @shipment.items.where(status: [:pending, :failed]).find_each { |item| item.update!(status: :cancelled, cancelled_at: Time.current) }
  end

  def log_event
    InternalTransferEvent.create!(internal_transfer: @shipment.internal_transfer, internal_transfer_shipment: @shipment,
                                  user: @user, action: 'cancelled', message: "Remessa de #{@shipment.origin_location.name} cancelada.")
  end
end
