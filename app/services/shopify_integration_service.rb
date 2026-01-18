class ShopifyIntegrationService
  def initialize(order_pdv = nil)
    @order_pdv = order_pdv
  end

  def integrate
    config = get_store_config(@order_pdv.store_type)
    shopify_session = create_shopify_session(config[:access_token])
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
                        first_name: @order_pdv.customer_name&.split&.first || 'Cliente',
                        last_name: @order_pdv.customer_name&.split(2)&.last || 'PDV',
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
        line_items:,
        customer: customer_data,
        billing_address: build_address_data,
        shipping_address: build_address_data,
        shipping_lines:,
        financial_status: 'pending',
        fulfillment_status: 'unfulfilled',
        tags: build_tags(config[:location_name]),
        note: @order_pdv.order_note,
        total_price: @order_pdv.total_price,
        subtotal_price: @order_pdv.subtotal,
        total_discounts: @order_pdv.discount_amount,
        source_name: @order_pdv.store_type,
        send_receipt: false,
        send_fulfillment_receipt: false
      }
    }

    Rails.logger.info "Criando pedido no Shopify para order_pdv #{@order_pdv.id}"
    order_response = client.post(path: 'orders.json', body: order_data)
    order = order_response.body['order']

    unless order && order['id']
      return {
        success: false,
        error: 'Resposta inválida do Shopify ao criar pedido'
      }
    end

    Rails.logger.info "Pedido criado no Shopify: #{order['id']}"

    reservation_results = reserve_and_commit_inventory(
      client, @order_pdv.order_pdv_items,
      config[:location_id],
      config[:location_name]
    )

    update_data = {
      reservation_status: reservation_results[:success] ? 'reserved' : 'reservation_error'
    }

    update_data[:inventory_reservations] = reservation_results[:reservations].to_json if @order_pdv.respond_to?(:inventory_reservations=) && reservation_results[:success]

    update_data[:reservation_error] = reservation_results[:error] if @order_pdv.respond_to?(:reservation_error=) && !reservation_results[:success]

    @order_pdv.update!(update_data)

    {
      success: true,
      order_id: order['id'],
      order_number: order['order_number'] || order['name'],
      location: config[:location_name],
      reservations: reservation_results[:reservations] || []
    }
  rescue ShopifyAPI::Errors::HttpResponseError => e
    Rails.logger.error "Erro HTTP do Shopify: #{e.message}"
    {
      success: false,
      error: e.message
    }
  rescue StandardError => e
    Rails.logger.error "Erro na integração: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    {
      success: false,
      error: e.message
    }
  end

  def self.search_products(query, store_type)
    Rails.logger.info "ShopifyIntegrationService.search_products called with query: '#{query}', store: '#{store_type}'"

    begin
      query_downcase = query.downcase

      products = Product.where(
        'LOWER(shopify_product_name) LIKE ? OR LOWER(sku) LIKE ? OR LOWER(option1) LIKE ? OR LOWER(option2) LIKE ? OR LOWER(option3) LIKE ?',
        "%#{query_downcase}%",
        "%#{query_downcase}%",
        "%#{query_downcase}%",
        "%#{query_downcase}%",
        "%#{query_downcase}%"
      ).limit(20)

      Rails.logger.info "Found #{products.count} products in local database"

      formatted_products = products.map do |product|
        Rails.logger.info "Processing product: #{product.sku} - #{product.shopify_product_name}"

        image_url = get_product_image_from_shopify(product, store_type)

        {
          id: product.shopify_variant_id,
          shopify_variant_id: product.shopify_variant_id,
          sku: product.sku,
          name: product.shopify_product_name,
          price: product.price.to_f,
          option1: product.option1,
          option2: product.option2,
          option3: product.option3,
          image_url:,
          vendor: product.vendor
        }
      end

      Rails.logger.info "Returning #{formatted_products.count} formatted products"
      formatted_products
    rescue StandardError => e
      Rails.logger.error "Error in search_products: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      []
    end
  end

  def self.get_product_by_id(variant_id)
    Rails.logger.info "ShopifyIntegrationService.get_product_by_id called with variant_id: #{variant_id}"

    begin
      product = Product.find_by(shopify_variant_id: variant_id)

      if product.nil?
        Rails.logger.warn "Product with variant_id #{variant_id} not found"
        return nil
      end

      image_url = get_product_image_from_shopify(product, 'lagoa_seca')

      {
        id: product.shopify_variant_id,
        shopify_variant_id: product.shopify_variant_id,
        sku: product.sku,
        name: product.shopify_product_name,
        price: product.price.to_f,
        option1: product.option1,
        option2: product.option2,
        option3: product.option3,
        image_url:,
        vendor: product.vendor
      }
    rescue StandardError => e
      Rails.logger.error "Error in get_product_by_id: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end
  end

  def self.create_order(_)
    Rails.logger.info 'ShopifyIntegrationService.create_order called'

    begin
      {
        'id' => "shopify_#{Time.current.to_i}",
        'order_number' => "PDV#{Time.current.to_i}",
        'name' => "#PDV#{Time.current.to_i}"
      }
    rescue StandardError => e
      Rails.logger.error "Error creating Shopify order: #{e.message}"
      nil
    end
  end

  def self.get_inventory_level(inventory_item_id, store_type = 'lagoa_seca')
    Rails.logger.info "Getting inventory level for item: #{inventory_item_id}, store: #{store_type}"

    begin
      config = get_store_config_static(store_type)
      session = create_shopify_session_static(config[:access_token])
      client = ShopifyAPI::Clients::Rest::Admin.new(session:)

      query = {
        inventory_item_ids: inventory_item_id,
        location_ids: config[:location_id]
      }

      response = client.get(path: 'inventory_levels.json', query:)

      inventory_levels = response.body['inventory_levels']

      if inventory_levels&.any?
        inventory_level = inventory_levels.first
        Rails.logger.info "Inventory level found: #{inventory_level['available']}"
        inventory_level
      else
        Rails.logger.warn "No inventory levels found for item #{inventory_item_id}"
        nil
      end
    rescue StandardError => e
      Rails.logger.error "Error getting inventory level: #{e.message}"
      nil
    end
  end

  def self.list_locations(store_type = 'lagoa_seca')
    Rails.logger.info "Listing all locations for store: #{store_type}"

    begin
      config = get_store_config_static(store_type)
      session = create_shopify_session_static(config[:access_token])
      client = ShopifyAPI::Clients::Rest::Admin.new(session:)

      response = client.get(path: 'locations.json')
      locations = response.body['locations']

      Rails.logger.info 'Available locations:'
      locations.each do |location|
        Rails.logger.info "  - #{location['name']} (ID: #{location['id']}) - Active: #{location['active']}"
      end

      locations

    rescue StandardError => e
      Rails.logger.error "Error listing locations: #{e.message}"
      []
    end
  end

  def self.get_store_config_static(store_type)
    case store_type
    when 'bh_shopping'
      {
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_BH_SHOPPING'),
        location_name: 'BH Shopping'
      }
    when 'rj'
      {
        access_token: ENV.fetch('BARRA_SHOPPING_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_BARRA_SHOPPING'),
        location_name: 'Barra Shopping'
      }
    when 'lagoa_seca'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_LAGOA_SECA'),
        location_name: 'Lagoa Seca'
      }
    when 'eldorado_sp'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_ELDORADO_SP'),
        location_name: 'Eldorado SP'
      }
    when 'fortaleza_rio_mar'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_FORTALEZA_RIO_MAR'),
        location_name: 'Fortaleza Rio Mar'
      }
    when 'porto_alegre_bourbon'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_PORTO_ALEGRE_BOURBON'),
        location_name: 'Porto Alegre Bourbon'
      }
    when 'shopping_analia_franco'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_SHOPPING_ANALIA_FRANCO'),
        location_name: 'Shopping Anália Franco'
      }
    end
  end

  def self.create_shopify_session_static(access_token)
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token:
    )
  end

  private

  def get_product_image_from_shopify(product, store_type)
    return nil unless product.shopify_product_id.present?

    begin
      config = get_store_config_static(store_type)
      session = create_shopify_session_static(config[:access_token])
      client = ShopifyAPI::Clients::Rest::Admin.new(session:)

      product_response = client.get(path: "products/#{product.shopify_product_id}.json")
      shopify_product = product_response.body['product']

      if shopify_product && shopify_product['images'] && shopify_product['images'].any?
        first_image = shopify_product['images'].first
        return first_image['src'] if first_image['src']
      end

      fallback_image_url(product)
    rescue StandardError => e
      Rails.logger.warn "Could not fetch image for product #{product.sku}: #{e.message}"
      fallback_image_url(product)
    end
  end

  def fallback_image_url(product)
    return unless product.sku.present?
    sku_clean = product.sku.downcase.gsub(/[^a-z0-9]/, '-')
    "https://cdn.shopify.com/s/files/1/0795/1650/2917/products/#{sku_clean}.jpg?v=1"
  end

  def reserve_and_commit_inventory(client, order_items, location_id, location_name)
    reservations = []

    begin
      Rails.logger.info "Iniciando reserva e commit de estoque na location #{location_name} (#{location_id})"

      order_items.each do |item|
        variant_id = item.product.shopify_variant_id
        quantity = item.quantity

        Rails.logger.info "Processando #{quantity} unidades do produto #{item.sku} (variant: #{variant_id})"

        variant_response = client.get(path: "variants/#{variant_id}.json")
        variant = variant_response.body['variant']

        unless variant
          Rails.logger.error "Variant #{variant_id} não encontrado"
          next
        end

        inventory_item_id = variant['inventory_item_id']

        query = { inventory_item_ids: inventory_item_id, location_ids: location_id }

        inventory_response = client.get(path: 'inventory_levels.json', query:)

        inventory_levels = inventory_response.body['inventory_levels']

        if inventory_levels.empty?
          Rails.logger.warn "Nível de estoque não encontrado para #{item.sku} na location #{location_name}"
          next
        end

        inventory_level = inventory_levels.first
        available_quantity = inventory_level['available'] || 0

        Rails.logger.info "Estoque disponível para #{item.sku} na #{location_name}: #{available_quantity}"

        if available_quantity < quantity
          Rails.logger.warn "Estoque insuficiente para #{item.sku} na #{location_name}. Disponível: #{available_quantity}, Solicitado: #{quantity}"
          reservations << {
            variant_id:,
            sku: item.sku,
            quantity:,
            location_id:,
            location_name:,
            available_quantity:,
            status: 'insufficient_stock',
            error: "Estoque insuficiente: #{available_quantity} disponível, #{quantity} solicitado"
          }
          next
        end

        begin
          body = {
            location_id:,
            inventory_item_id:,
            available_adjustment: -quantity,
            reason: "Pedido PDV ##{@order_pdv.id} - Reservado e Committed"
          }

          adjustment_response = client.post(
            path: 'inventory_levels/adjust.json',
            body:
          )

          if adjustment_response.code == 200
            Rails.logger.info "Estoque ajustado (reservado) com sucesso para #{item.sku}: #{quantity} unidades"

            begin
              query = { inventory_item_ids: inventory_item_id, location_ids: location_id }

              updated_inventory_response = client.get(path: 'inventory_levels.json', query:)

              updated_inventory_levels = updated_inventory_response.body['inventory_levels']

              if updated_inventory_levels.any?
                body = { location_id:, inventory_item_id:, available_adjustment: 0, reason: "Pedido PDV ##{@order_pdv.id} - Committed" }

                commit_response = client.post(path: 'inventory_levels/adjust.json', body: )

                Rails.logger.info "Estoque marcado como committed para #{item.sku}: #{quantity} unidades"

                reservations << {
                  variant_id:,
                  sku: item.sku,
                  quantity:,
                  location_id:,
                  location_name:,
                  available_quantity:,
                  reserved_quantity: quantity,
                  status: 'committed',
                  adjustment_id: adjustment_response.body.dig('inventory_level', 'id'),
                  commit_id: commit_response.body.dig('inventory_level', 'id')
                }
              else
                Rails.logger.warn 'Não foi possível encontrar inventory level atualizado para commit'
                reservations << {
                  variant_id:,
                  sku: item.sku,
                  quantity:,
                  location_id:,
                  location_name:,
                  available_quantity:,
                  reserved_quantity: quantity,
                  status: 'reserved_only',
                  adjustment_id: adjustment_response.body.dig('inventory_level', 'id')
                }
              end
            rescue StandardError => e
              Rails.logger.error "Erro ao fazer commit do estoque para #{item.sku}: #{e.message}"
              reservations << {
                variant_id:,
                sku: item.sku,
                quantity:,
                location_id:,
                location_name:,
                available_quantity:,
                reserved_quantity:,
                status: 'reserved_only',
                adjustment_id: adjustment_response.body.dig('inventory_level', 'id'),
                error: "Erro no commit: #{commit_error.message}"
              }
            end
          else
            Rails.logger.error "Falha ao reservar estoque para #{item.sku}: #{adjustment_response.body}"
            reservations << {
              variant_id:,
              sku: item.sku,
              quantity:,
              location_id:,
              location_name:,
              available_quantity:,
              status: 'reservation_failed',
              error: "Falha na reserva: #{adjustment_response.body}"
            }
          end
        rescue StandardError => e
          Rails.logger.error "Erro ao fazer adjustment de estoque para #{item.sku}: #{e.message}"
          reservations << {
            variant_id:,
            sku: item.sku,
            quantity:,
            location_id:,
            location_name:,
            available_quantity:,
            status: 'verified_only',
            error: "Erro na reserva: #{adjustment_error.message}"
          }
        end
      end

      success = reservations.any? { |r| ['committed', 'reserved_only'].include?(r[:status]) }

      {
        success:,
        reservations:,
        summary: {
          total_items: reservations.count,
          committed: reservations.count { |r| r[:status] == 'committed' },
          reserved_only: reservations.count { |r| r[:status] == 'reserved_only' },
          insufficient_stock: reservations.count { |r| r[:status] == 'insufficient_stock' },
          failed: reservations.count { |r| r[:status] == 'reservation_failed' }
        }
      }
    rescue StandardError => e
      Rails.logger.error "Erro durante reserva e commit de estoque: #{e.message}"
      {
        success: false,
        error: e.message,
        partial_reservations: reservations
      }
    end
  end

  def get_store_config(store_type)
    case store_type
    when 'bh_shopping'
      {
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_BH_SHOPPING'),
        location_name: 'BH Shopping'
      }
    when 'rj'
      {
        access_token: ENV.fetch('BARRA_SHOPPING_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_BARRA_SHOPPING'),
        location_name: 'Barra Shopping'
      }
    when 'lagoa_seca'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_LAGOA_SECA'),
        location_name: 'Lagoa Seca'
      }
    when 'eldorado_sp'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_ELDORADO_SP'),
        location_name: 'Eldorado SP'
      }
    when 'fortaleza_rio_mar'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_FORTALEZA_RIO_MAR'),
        location_name: 'Fortaleza Rio Mar'
      }
    when 'porto_alegre_bourbon'
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_PORTO_ALEGRE_BOURBON'),
        location_name: 'Porto Alegre Bourbon'
      }
    end
  end

  def create_shopify_session(access_token)
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token:
    )
  end

  def find_existing_customer(client, email, phone)
    return nil if email.blank? && phone.blank?

    begin
      if email.present?
        response = client.get(path: 'customers/search.json', query: { query: "email:#{email}" })
        customers = response.body['customers']
        return customers.first if customers.any?
      end

      if phone.present?
        formatted_phone = format_phone_for_shopify(phone)
        response = client.get(path: 'customers/search.json', query: { query: "phone:#{formatted_phone}" })
        customers = response.body['customers']
        return customers.first if customers.any?
      end

      nil
    rescue StandardError => e
      Rails.logger.error "Erro ao buscar cliente: #{e.message}"
      nil
    end
  end

  def build_address_data
    {
      first_name: @order_pdv.customer_name&.split&.first || 'Cliente',
      last_name: @order_pdv.customer_name&.split(' ', 2)&.last || 'PDV',
      address1: @order_pdv.address1,
      address2: @order_pdv.address2,
      city: @order_pdv.city,
      province: @order_pdv.state,
      zip: @order_pdv.zip,
      country: 'BR'
    }
  end

  def build_tags(location_name)
    tags = ['PDV', @order_pdv.store_type, @order_pdv.payment_method, @order_pdv.user.name, "SEDEX", "NAO_PAGO", "NAO_PROCESSADO", location_name]

    if @order_pdv.has_parcels?
      tags << 'PARCELADO'
      tags << "#{@order_pdv.order_parcels.count}_PARCELAS"

      payment_methods = @order_pdv.order_parcels.pluck(:payment_method).uniq
      payment_methods.each do |method|
        tags << method.upcase
      end
    end

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
end
