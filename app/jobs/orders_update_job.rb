class OrdersUpdateJob < ApplicationJob
  queue_as :default

  # ============================================================
  # ENTRY POINT
  # ============================================================

  def perform(action:, **options)
    case action
    when 'sync_all'
      sync_all_orders(options)
    when 'sync_single'
      sync_single_order(options)
    when 'update_staff_and_payments'
      update_staff_and_payments(options)
    when 'sync_customers_from_orders'
      sync_customers_from_orders(options)
    else
      Rails.logger.error "[OrdersUpdateJob] Ação desconhecida: #{action}"
    end
  rescue StandardError => e
    Rails.logger.error "[OrdersUpdateJob] Erro: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  # ============================================================
  # SYNC ALL ORDERS
  # ============================================================

  def sync_all_orders(options)
    limit  = options[:limit] || 50
    status = options[:status] || 'any'

    Rails.logger.info "[OrdersUpdateJob] Iniciando sincronização (limit: #{limit}, status: #{status})"

    Shopify::Orders.sync_shopify_orders_to_rails(
      limit: limit,
      status: status
    )
  end

  # ============================================================
  # SYNC SINGLE ORDER
  # ============================================================

  def sync_single_order(options)
    shopify_order_id = options[:shopify_order_id]
    raise ArgumentError, 'shopify_order_id é obrigatório' if shopify_order_id.blank?

    Rails.logger.info "[OrdersUpdateJob] Sincronizando pedido #{shopify_order_id}"

    session = build_shopify_session

    shopify_order = ShopifyAPI::Order.find(
      session: session,
      id: shopify_order_id,
      fields: 'id,name,email,created_at,total_price,line_items,customer,financial_status,fulfillment_status,note_attributes'
    )

    return unless shopify_order

    order = Shopify::Orders.create_or_update_order_from_shopify(
      shopify_order.as_json
    )

    Rails.logger.info "[OrdersUpdateJob] Pedido sincronizado: #{order&.id}"
    order
  end

  # ============================================================
  # UPDATE STAFF AND PAYMENTS
  # ============================================================

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

  # ============================================================
  # 🔥 SYNC CUSTOMERS FROM EXISTING ORDERS
  # ============================================================

  def sync_customers_from_orders(options)
    batch_size = options[:batch_size] || 50

    Rails.logger.info "[OrdersUpdateJob] Iniciando sync de customers via orders"

    session = build_shopify_session

    Order.where.not(shopify_order_id: nil).where(customer_id: nil)
         .find_in_batches(batch_size: batch_size) do |orders|

      orders.each do |order|
        begin
          sync_customer_for_order(order, session)
        rescue => e
          Rails.logger.error "[OrdersUpdateJob] Erro no order #{order.id}: #{e.message}"
        end
      end
    end

    Rails.logger.info "[OrdersUpdateJob] Sync de customers finalizado"
  end

  # ============================================================
  # PRIVATE
  # ============================================================

  private

  # -----------------------------
  # Shopify Session
  # -----------------------------
  def build_shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
  end

  # -----------------------------
  # Sync individual order customer
  # -----------------------------
  def sync_customer_for_order(order, session)
    return if order.shopify_order_id.blank?

    shopify_order = ShopifyAPI::Order.find(
      session: session,
      id: order.shopify_order_id,
      fields: 'id,customer'
    )

    return unless shopify_order&.customer

    shopify_customer = shopify_order.customer

    customer = Customer.find_or_initialize_by(
      shopify_customer_id: shopify_customer.id.to_s
    )

    assign_full_customer_data(customer, shopify_customer)

    customer.save! if customer.changed?

    order.update!(customer_id: customer.id)

    Rails.logger.info "[OrdersUpdateJob] Order #{order.id} atualizado com customer #{customer.id}"
  end

  # -----------------------------
  # Assign full Shopify customer data
  def assign_full_customer_data(customer, shopify_customer)
    # Garantir que seja hash
    data = shopify_customer.respond_to?(:as_json) ? shopify_customer.as_json : shopify_customer

    default_address = data['default_address'] || {}
    addresses = data['addresses'] || []

    customer.assign_attributes(
      first_name: data['first_name'],
      last_name: data['last_name'],
      email: data['email'],
      phone: data['phone'],
      currency: data['currency'],
      tags: data['tags'],
      orders_count: data['orders_count'],
      total_spent: data['total_spent'],
      verified_email: data['verified_email'],
      tax_exempt: data['tax_exempt'],
      shopify_created_at: data['created_at'],
      shopify_updated_at: data['updated_at'],
      addresses: addresses
    )

    if default_address.present?
      customer.assign_attributes(
        default_address_name: default_address['name'],
        default_address_company: default_address['company'],
        default_address_phone: default_address['phone'],
        default_address_address1: default_address['address1'],
        default_address_address2: default_address['address2'],
        default_address_city: default_address['city'],
        default_address_province: default_address['province'],
        default_address_country: default_address['country'],
        default_address_zip: default_address['zip'],
        default_address_country_code: default_address['country_code'],
        default_address_province_code: default_address['province_code']
      )
    end
  end
end