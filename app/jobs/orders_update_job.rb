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

    when 'sync_shopify_orders_routine'
      sync_shopify_orders_routine(options)

    else
      Rails.logger.error "[OrdersUpdateJob] Ação desconhecida: #{action}"
    end
  rescue StandardError => e
    Rails.logger.error "[OrdersUpdateJob] Erro: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise e
  end

  def sync_all_orders(options)
    limit  = options[:limit] || 100
    status = options[:status] || 'any'

    Rails.logger.info '[OrdersUpdateJob] Iniciando sincronização completa'

    Shopify::Orders.sync_shopify_orders_to_rails(
      limit:,
      status:,
      time_range: :all
    )
  end

  def sync_shopify_orders_routine(options)
    limit   = options[:limit] || 250
    status  = options[:status] || 'any'
    routine = options[:routine] || :last_3_hours

    Rails.logger.info "[OrdersUpdateJob] Iniciando rotina Shopify (#{routine})"

    Shopify::Orders.sync_shopify_orders_to_rails(
      limit:,
      status:,
      time_range: routine
    )

    sync_customers_from_orders(batch_size: 50)
  end

  def sync_single_order(options)
    shopify_order_id = options[:shopify_order_id]
    raise ArgumentError, 'shopify_order_id é obrigatório' if shopify_order_id.blank?

    session = build_shopify_session

    shopify_order = ShopifyAPI::Order.find(
      session:,
      id: shopify_order_id,
      fields: 'id,name,email,created_at,total_price,line_items,customer,financial_status,fulfillment_status,note_attributes'
    )

    return unless shopify_order

    Shopify::Orders.create_or_update_order_from_shopify(
      shopify_order.as_json
    )
  end

  def update_staff_and_payments(options)
    shopify_order_id = options[:shopify_order_id]
    raise ArgumentError, 'shopify_order_id é obrigatório' if shopify_order_id.blank?

    Shopify::Orders.update_order_staff_and_payments(
      shopify_order_id,
      staff_id: options[:staff_id],
      staff_name: options[:staff_name],
      iglu_payments: options[:iglu_payments]
    )
  end

  def sync_customers_from_orders(options)
    batch_size = options[:batch_size] || 50

    session = build_shopify_session

    Order.where.not(shopify_order_id: nil).where(customer_id: nil)
         .find_in_batches(batch_size:) do |orders|
      orders.each do |order|
        sync_customer_for_order(order, session)
      rescue StandardError => e
        Rails.logger.error "[OrdersUpdateJob] Erro no order #{order.id}: #{e.message}"
      end
    end
  end

  private

  def build_shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
  end

  def sync_customer_for_order(order, session)
    return if order.shopify_order_id.blank?

    shopify_order = ShopifyAPI::Order.find(
      session:,
      id: order.shopify_order_id,
      fields: 'id,customer'
    )

    return unless shopify_order&.customer

    shopify_customer = shopify_order.customer

    customer = Customer.find_or_initialize_by(
      shopify_customer_id: shopify_customer.id.to_s
    )

    Shopify::Orders.assign_full_customer_data(customer, shopify_customer)

    customer.save! if customer.changed?

    order.update!(customer_id: customer.id)

    Rails.logger.info "[OrdersUpdateJob] Order #{order.id} atualizado com customer #{customer.id}"
  end
end
