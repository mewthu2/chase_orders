# Reverte UMA linha já retirada: devolve a quantidade ao estoque no Shopify (adição de estoque,
# lançada no histórico do inventário como correção, com referência à retirada e à linha) e marca
# a linha como revertida. O status da retirada é recalculado (parcialmente concluída / revertida).
#
# Síncrono e à prova de clique duplo: dentro do lock a linha é relida e só uma reversão passa.
class StockWithdrawalReverter
  class Error < StandardError; end

  SHOPIFY_REASON = 'correction'.freeze

  def self.call(item, user:)
    new(item, user: user).call
  end

  def initialize(item, user:)
    @item = item
    @user = user
    @withdrawal = item.stock_withdrawal
  end

  def call
    @withdrawal.with_lock do
      @item.reload # cópia velha (clique duplo) enxerga o estado atual
      validate!
      result = adjust_in_shopify
      raise Error, "O Shopify não aceitou a devolução: #{result[:error]}" unless result[:success]

      @item.update!(status: :reverted, reverted_at: Time.current, reverted_by: @user, reversal_adjustment_id: result[:adjustment_id])
      restore_local_stock
      @withdrawal.refresh_status!
    end
    log
    @item
  end

  private

  def validate!
    raise Error, 'Só é possível reverter uma linha que já foi retirada do Shopify.' unless @item.done?
    raise Error, 'A retirada está em processamento agora. Aguarde alguns minutos.' if @withdrawal.processing? && !@withdrawal.stale_processing?
    raise Error, "Location #{@item.location.name} sem ID do Shopify" if @item.location.shopify_location_id.blank?
  end

  def adjust_in_shopify
    ShopifyInventoryService.new.adjust_available(
      location_id: @item.location.shopify_location_id,
      changes: [{ inventory_item_id: @item.product.shopify_inventory_item_id, delta: @item.quantity }],
      reason: SHOPIFY_REASON,
      reference_uri: "honey://stock-withdrawal/#{@withdrawal.id}?motivo=reversao&linha=#{@item.id}"
    )
  end

  # Devolve a quantidade ao estoque local do produto naquela location (quando existe coluna para ela).
  def restore_local_stock
    column = "stock_#{@item.location.slug}"
    product = @item.product.reload
    product.update(column => product[column].to_i + @item.quantity) if product.respond_to?(column)
  end

  def log
    LogService.create_log(
      user: @user, resource_type: 'stock_withdrawal', action_type: 'revert_item',
      resource_name: "Retirada ##{@withdrawal.id}", resource_id: @withdrawal.id,
      details: { item_id: @item.id, sku: @item.product.sku, location: @item.location.name, quantity: @item.quantity,
                 adjustment_id: @item.reversal_adjustment_id }
    )
  end
end
