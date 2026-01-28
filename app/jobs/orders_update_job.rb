class OrdersUpdateJob < ApplicationJob
  queue_as :default

  def perform(action:, **options)
    case action
    when 'sync_all'
      sync_all_orders(options)
    when 'sync_single'
      sync_single_order(options)
    when 'update_staff_and_payments'
      update_staff_and_payments(options)
    else
      Rails.logger.error "[OrdersUpdateJob] Ação desconhecida: #{action}"
    end
  rescue StandardError => e
    Rails.logger.error "[OrdersUpdateJob] Erro: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  private

  def sync_all_orders(options)
    limit  = options[:limit] || 50
    status = options[:status] || 'any'

    Rails.logger.info "[OrdersUpdateJob] Iniciando sincronização (limit: #{limit}, status: #{status})"
    Shopify::Orders.sync_shopify_orders_to_rails(limit: limit, status: status)
  end

  def sync_single_order(options)
    shopify_order_id = options[:shopify_order_id]
    raise ArgumentError, 'shopify_order_id é obrigatório' if shopify_order_id.blank?

    Rails.logger.info "[OrdersUpdateJob] Sincronizando pedido #{shopify_order_id}"

    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )

    shopify_order = ShopifyAPI::Order.find(
      session: session,
      id: shopify_order_id,
      fields: 'id,name,email,created_at,total_price,line_items,customer,financial_status,fulfillment_status,note_attributes'
    )

    return unless shopify_order

    iglu_payments = extract_iglu_payments(shopify_order)

    order = Shopify::Orders.create_or_update_order_from_shopify(
      shopify_order,
      staff_id: extract_note(shopify_order, 'staff_ID'),
      staff_name: extract_note(shopify_order, 'staff_name'),
      iglu_payments: iglu_payments
    )

    Rails.logger.info "[OrdersUpdateJob] Pedido sincronizado: #{order&.id}"
    order
  end

  def update_staff_and_payments(options)
    shopify_order_id = options[:shopify_order_id]
    raise ArgumentError, 'shopify_order_id é obrigatório' if shopify_order_id.blank?

    Rails.logger.info "[OrdersUpdateJob] Atualizando staff/pagamentos #{shopify_order_id}"

    Shopify::Orders.update_order_staff_and_payments(
      shopify_order_id,
      staff_id: options[:staff_id],
      staff_name: options[:staff_name],
      iglu_payments: options[:iglu_payments]
    )
  end

  # ============================
  # Helpers
  # ============================

  def extract_note(shopify_order, key)
    shopify_order.note_attributes
                 &.find { |n| n['name'] == key }
                 &.dig('value')
  end

  def extract_iglu_payments(shopify_order)
    raw = extract_note(shopify_order, 'iglu_payments')
    return [] if raw.blank?

    JSON.parse(raw)
  rescue JSON::ParserError
    Rails.logger.warn '[OrdersUpdateJob] iglu_payments com JSON inválido'
    []
  end
end
