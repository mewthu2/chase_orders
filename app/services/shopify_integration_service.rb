class ShopifyIntegrationService
  def initialize(order_pdv)
    @order_pdv = order_pdv
  end

  def integrate
    begin
      shopify_session = create_shopify_session
      client = ShopifyAPI::Clients::Rest::Admin.new(session: shopify_session)

      existing_customer = find_existing_customer(client, @order_pdv.customer_email, @order_pdv.customer_phone)

      line_items = @order_pdv.order_pdv_items.map do |item|
        {
          variant_id: item.product.shopify_variant_id,
          quantity: item.quantity,
          price: item.price.to_f
        }
      end

      customer_data = if existing_customer
        { id: existing_customer['id'] }
      else
        {
          first_name: @order_pdv.customer_name&.split(' ')&.first || 'Cliente',
          last_name: @order_pdv.customer_name&.split(' ', 2)&.last || 'PDV',
          email: @order_pdv.customer_email,
          phone: format_phone_for_shopify(@order_pdv.customer_phone)
        }
      end

      shipping_lines = [
        {
          title: 'SEDEX',
          price: '0.00',
          code: 'SEDEX',
          source: 'shopify'
        }
      ]

      order_data = {
        order: {
          line_items: line_items,
          customer: customer_data,
          billing_address: build_address_data,
          shipping_address: build_address_data,
          shipping_lines: shipping_lines,
          financial_status: 'pending',
          tags: build_tags,
          note: @order_pdv.order_note,
          total_price: @order_pdv.total_price,
          subtotal_price: @order_pdv.subtotal,
          total_discounts: @order_pdv.discount_amount,
          source_name: @order_pdv.store_type,
          send_receipt: false,
          send_fulfillment_receipt: false
        }
      }

      order_response = client.post(path: 'orders.json', body: order_data)
      order = order_response.body['order']

      if order && order['id']
        begin
          create_fulfillment(client, order['id'], get_location_id(@order_pdv.store_type))
        rescue => e
          Rails.logger.error "Erro ao criar fulfillment: #{e.message}"
        end

        {
          success: true,
          order_id: order['id'],
          order_number: order['order_number'] || order['name']
        }
      else
        {
          success: false,
          error: "Resposta inválida do Shopify"
        }
      end

    rescue ShopifyAPI::Errors::HttpResponseError => e
      Rails.logger.error "Erro HTTP do Shopify: #{e.message}"
      {
        success: false,
        error: e.message
      }
    rescue => e
      Rails.logger.error "Erro na integração: #{e.message}"
      {
        success: false,
        error: e.message
      }
    end
  end

  private

  def create_shopify_session
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV['LAGOA_SECA_TOKEN_APP']
    )
  end

  def find_existing_customer(client, email, phone)
    return nil if email.blank? && phone.blank?

    begin
      if email.present?
        response = client.get(path: "customers/search.json", query: { query: "email:#{email}" })
        customers = response.body['customers']
        return customers.first if customers.any?
      end

      if phone.present?
        formatted_phone = format_phone_for_shopify(phone)
        response = client.get(path: "customers/search.json", query: { query: "phone:#{formatted_phone}" })
        customers = response.body['customers']
        return customers.first if customers.any?
      end

      nil
    rescue => e
      Rails.logger.error "Erro ao buscar cliente: #{e.message}"
      nil
    end
  end

  def build_address_data
    {
      first_name: @order_pdv.customer_name&.split(' ')&.first || 'Cliente',
      last_name: @order_pdv.customer_name&.split(' ', 2)&.last || 'PDV',
      address1: @order_pdv.address1,
      address2: @order_pdv.address2,
      city: @order_pdv.city,
      province: @order_pdv.state,
      zip: @order_pdv.zip,
      country: 'BR'
    }
  end

  def build_tags
    tags = ["PDV", @order_pdv.store_type, @order_pdv.payment_method, @order_pdv.user.name, "SEDEX", "NAO_PAGO"]
    tags.join(',')
  end

  def format_phone_for_shopify(phone)
    return nil if phone.nil? || phone.empty?
    
    cleaned_phone = phone.gsub(/\D/, '')

    if cleaned_phone.start_with?('55')
      cleaned_phone
    elsif cleaned_phone.start_with?('0')
      cleaned_phone = "55#{cleaned_phone[1..]}"
    else
      cleaned_phone = "55#{cleaned_phone}"
    end

    if cleaned_phone.length == 12
      ddd = cleaned_phone[2..3]
      numero = cleaned_phone[4..]
      cleaned_phone = "55#{ddd}9#{numero}"
    end

    cleaned_phone = cleaned_phone[0, 13] if cleaned_phone.length > 13
    "+#{cleaned_phone}"
  end

  def get_location_id(store_type)
    case store_type
    when 'bh_shopping'
      ENV['LOCATION_BH_SHOPPING']
    when 'rj'
      ENV['LOCATION_BARRA_SHOPPING']
    when 'lagoa_seca'
      ENV['LOCATION_LAGOA_SECA']
    else
      ENV['LOCATION_LAGOA_SECA']
    end
  end

  def create_fulfillment(client, order_id, location_id)
    return unless location_id

    fulfillment_orders_response = client.get(path: "orders/#{order_id}/fulfillment_orders.json")
    fulfillment_orders = fulfillment_orders_response.body['fulfillment_orders']

    fulfillment_orders.each do |fo|
      if fo['assigned_location_id'] != location_id.to_i && fo['supported_actions'].include?('move')
        client.post(path: "fulfillment_orders/#{fo['id']}/move.json",
          body: { fulfillment_order: { new_location_id: location_id } }
        )
      end

      client.post(path: 'fulfillments.json',
        body: {
          fulfillment: {
            message: 'Pedido entregue em mãos - PDV.',
            notify_customer: false,
            line_items_by_fulfillment_order: [{ fulfillment_order_id: fo['id'] }],
            location_id: location_id
          }
        }
      )
    end
  end
end
