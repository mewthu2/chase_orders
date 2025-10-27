class ShopifyAbandonedCheckoutService
  def initialize
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )
    @client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def fetch_abandoned_checkouts(since: 1.hour.ago)
    begin
      Rails.logger.info "Fetching abandoned checkouts since #{since}"
      
      query = {
        status: 'open',
        created_at_min: since.iso8601,
        limit: 250
      }
      
      response = @client.get(path: 'checkouts.json', query: query)
      checkouts = response.body['checkouts'] || []
      
      Rails.logger.info "Found #{checkouts.count} abandoned checkouts"
      
      parse_checkouts(checkouts)
    rescue StandardError => e
      Rails.logger.error "Error fetching abandoned checkouts: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      []
    end
  end

  private

  def parse_checkouts(checkouts_data)
    return [] unless checkouts_data.is_a?(Array)

    checkouts_data.map do |checkout|
      phone = checkout.dig('billing_address', 'phone') || 
              checkout.dig('shipping_address', 'phone') || 
              checkout['phone']
      
      {
        checkout_id: checkout['id'],
        checkout_token: checkout['token'],
        email: checkout['email'],
        phone: phone,
        customer_name: build_customer_name(checkout),
        total_price: checkout['total_price'],
        subtotal_price: checkout['subtotal_price'],
        currency: checkout['currency'],
        created_at: checkout['created_at'],
        updated_at: checkout['updated_at'],
        abandoned_checkout_url: checkout['abandoned_checkout_url'],
        line_items: parse_line_items(checkout['line_items']),
        shipping_address: parse_shipping_address(checkout['shipping_address']),
        billing_address: parse_billing_address(checkout['billing_address']),
        customer_data: parse_customer(checkout['customer'])
      }
    end
  end

  def build_customer_name(checkout)
    if checkout['customer'] && checkout['customer']['first_name'].present?
      "#{checkout['customer']['first_name']} #{checkout['customer']['last_name']}".strip
    elsif checkout['shipping_address'] && checkout['shipping_address']['first_name'].present?
      "#{checkout['shipping_address']['first_name']} #{checkout['shipping_address']['last_name']}".strip
    elsif checkout['billing_address'] && checkout['billing_address']['first_name'].present?
      "#{checkout['billing_address']['first_name']} #{checkout['billing_address']['last_name']}".strip
    elsif checkout['email'].present?
      checkout['email'].split('@').first.titleize
    else
      'Cliente'
    end
  end

  def parse_line_items(line_items_data)
    return [] unless line_items_data.is_a?(Array)

    line_items_data.map do |item|
      {
        title: item['title'],
        quantity: item['quantity'],
        variant_id: item['variant_id'],
        variant_title: item['variant_title'],
        price: item['price'],
        product_id: item['product_id'],
        sku: item['sku'],
        vendor: item['vendor']
      }
    end
  end

  def parse_shipping_address(address)
    return nil unless address.is_a?(Hash)

    {
      name: "#{address['first_name']} #{address['last_name']}".strip,
      first_name: address['first_name'],
      last_name: address['last_name'],
      address1: address['address1'],
      address2: address['address2'],
      city: address['city'],
      province: address['province'],
      province_code: address['province_code'],
      country: address['country'],
      country_code: address['country_code'],
      zip: address['zip'],
      phone: address['phone']
    }
  end

  def parse_billing_address(address)
    return nil unless address.is_a?(Hash)

    {
      name: "#{address['first_name']} #{address['last_name']}".strip,
      first_name: address['first_name'],
      last_name: address['last_name'],
      address1: address['address1'],
      address2: address['address2'],
      city: address['city'],
      province: address['province'],
      province_code: address['province_code'],
      country: address['country'],
      country_code: address['country_code'],
      zip: address['zip'],
      phone: address['phone']
    }
  end

  def parse_customer(customer)
    return nil unless customer.is_a?(Hash)

    {
      id: customer['id'],
      name: "#{customer['first_name']} #{customer['last_name']}".strip,
      first_name: customer['first_name'],
      last_name: customer['last_name'],
      email: customer['email'],
      phone: customer['phone'],
      accepts_marketing: customer['accepts_marketing'],
      orders_count: customer['orders_count'],
      total_spent: customer['total_spent']
    }
  end
end
