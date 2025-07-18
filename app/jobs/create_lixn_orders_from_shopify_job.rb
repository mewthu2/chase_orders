class CreateLixnOrdersFromShopifyJob < BaseShopifyLixnJob
  require 'uri'

  SHOPIFY_ORDER_REQUEST_LIMIT = 250

  # This job imports orders from Shopify to Lixn based on the specified kind.
  # @param kind [Symbol] The kind of shopping (e.g., :bh_shopping, :rj, :lagoa_seca).
  # @return [void]
  def perform(kind)
    start_at = Time.zone.now
    puts "Iniciando importação de pedidos da Shopify de (#{kind}) para Lixn... em #{start_at}"

    orders_request(kind)
    process_orders(kind)

    puts "Finalizando importação de pedidos da Shopify de (#{kind}) para Lixn em #{Time.zone.now - start_at}"
  end

  private

  # Returns the fields to be requested for each order from Shopify.
  # @return [String] A comma-separated string of fields to be included in the order request.
  def order_shopify_show_request_fields
    'id,created_at,contact_email,phone,currency,current_subtotal_price,current_subtotal_price_set,
      current_total_discounts,current_total_discounts_set,current_total_duties_set,current_total_price,
      current_total_price_set,current_total_tax,financial_status,order_status_url,line_items'
  end
end