class ShopifyIntegrationService
  def initialize(order_pdv)
    @order_pdv = order_pdv
  end

  def integrate
    begin
      # Configurar token e location baseado na loja
      config = get_store_config(@order_pdv.store_type)
      
      shopify_session = create_shopify_session(config[:access_token])
      client = ShopifyAPI::Clients::Rest::Admin.new(session: shopify_session)
      graphql_client = ShopifyAPI::Clients::Graphql::Admin.new(session: shopify_session)

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

      # 1. Criar o pedido no Shopify
      Rails.logger.info "Criando pedido no Shopify para order_pdv #{@order_pdv.id}"
      order_response = client.post(path: 'orders.json', body: order_data)
      order = order_response.body['order']

      unless order && order['id']
        return {
          success: false,
          error: "Resposta inválida do Shopify ao criar pedido"
        }
      end

      Rails.logger.info "Pedido criado no Shopify: #{order['id']}"

      # 2. Reservar estoque na location específica
      reservation_results = reserve_inventory_at_location(
        graphql_client, 
        @order_pdv.order_pdv_items, 
        config[:location_id],
        config[:location_name]
      )

      if reservation_results[:success]
        Rails.logger.info "Estoque reservado com sucesso na location #{config[:location_name]}"
        
        {
          success: true,
          order_id: order['id'],
          order_number: order['order_number'] || order['name'],
          location: config[:location_name],
          reservations: reservation_results[:reservations]
        }
      else
        Rails.logger.error "Falha ao reservar estoque: #{reservation_results[:error]}"
        
        # Pedido foi criado mas estoque não foi reservado
        # Vamos manter o pedido mas sinalizar o problema
        {
          success: true,
          order_id: order['id'],
          order_number: order['order_number'] || order['name'],
          location: config[:location_name],
          warning: "Pedido criado mas estoque não foi reservado: #{reservation_results[:error]}"
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
      Rails.logger.error e.backtrace.join("\n")
      {
        success: false,
        error: e.message
      }
    end
  end

  private

  def reserve_inventory_at_location(graphql_client, order_items, location_id, location_name)
    reservations = []
    
    begin
      Rails.logger.info "Iniciando reserva de estoque na location #{location_name} (#{location_id})"
      
      order_items.each do |item|
        variant_id = item.product.shopify_variant_id
        quantity = item.quantity
        
        Rails.logger.info "Reservando #{quantity} unidades do produto #{item.sku} (variant: #{variant_id})"
        
        # Verificar estoque disponível antes de reservar
        stock_check = check_inventory_at_location(graphql_client, variant_id, location_id)
        
        unless stock_check[:success]
          raise "Erro ao verificar estoque do produto #{item.sku}: #{stock_check[:error]}"
        end
        
        available_quantity = stock_check[:available_quantity]
        
        if available_quantity < quantity
          raise "Estoque insuficiente para #{item.sku}. Disponível: #{available_quantity}, Solicitado: #{quantity}"
        end
        
        # Criar reserva de inventory
        reservation_result = create_inventory_reservation(
          graphql_client, 
          variant_id, 
          location_id, 
          quantity,
          "PDV Order ##{@order_pdv.id} - #{item.sku}"
        )
        
        if reservation_result[:success]
          reservations << {
            variant_id: variant_id,
            sku: item.sku,
            quantity: quantity,
            location_id: location_id,
            reservation_id: reservation_result[:reservation_id]
          }
          
          Rails.logger.info "Reserva criada com sucesso para #{item.sku}: #{reservation_result[:reservation_id]}"
        else
          raise "Falha ao reservar estoque para #{item.sku}: #{reservation_result[:error]}"
        end
      end
      
      {
        success: true,
        reservations: reservations
      }
      
    rescue => e
      Rails.logger.error "Erro durante reserva de estoque: #{e.message}"
      
      # Tentar reverter reservas já criadas
      if reservations.any?
        Rails.logger.info "Tentando reverter #{reservations.count} reservas já criadas"
        cancel_inventory_reservations(graphql_client, reservations)
      end
      
      {
        success: false,
        error: e.message,
        partial_reservations: reservations
      }
    end
  end

  def check_inventory_at_location(graphql_client, variant_id, location_id)
    begin
      query = <<~GRAPHQL
        query($variantId: ID!, $locationId: ID!) {
          productVariant(id: $variantId) {
            id
            sku
            inventoryItem {
              id
              inventoryLevels(locationIds: [$locationId], first: 1) {
                edges {
                  node {
                    id
                    available
                    location {
                      id
                      name
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      variables = {
        variantId: "gid://shopify/ProductVariant/#{variant_id}",
        locationId: "gid://shopify/Location/#{location_id}"
      }

      response = graphql_client.query(query: query, variables: variables)
      
      if response.body['errors']
        return {
          success: false,
          error: response.body['errors'].map { |e| e['message'] }.join(', ')
        }
      end

      variant = response.body.dig('data', 'productVariant')
      
      unless variant
        return {
          success: false,
          error: 'Produto não encontrado'
        }
      end

      inventory_level = variant.dig('inventoryItem', 'inventoryLevels', 'edges', 0, 'node')
      
      unless inventory_level
        return {
          success: false,
          error: 'Nível de estoque não encontrado para esta location'
        }
      end

      {
        success: true,
        available_quantity: inventory_level['available'] || 0,
        location_name: inventory_level.dig('location', 'name')
      }
      
    rescue => e
      Rails.logger.error "Erro ao verificar estoque: #{e.message}"
      {
        success: false,
        error: e.message
      }
    end
  end

  def create_inventory_reservation(graphql_client, variant_id, location_id, quantity, note)
    begin
      mutation = <<~GRAPHQL
        mutation($input: InventoryReserveInput!) {
          inventoryReserve(input: $input) {
            inventoryReservation {
              id
              quantity
              note
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      variables = {
        input: {
          inventoryItemId: get_inventory_item_id(graphql_client, variant_id),
          locationId: "gid://shopify/Location/#{location_id}",
          quantity: quantity,
          note: note
        }
      }

      response = graphql_client.query(query: mutation, variables: variables)
      
      if response.body['errors']
        return {
          success: false,
          error: response.body['errors'].map { |e| e['message'] }.join(', ')
        }
      end

      result = response.body.dig('data', 'inventoryReserve')
      
      if result['userErrors']&.any?
        return {
          success: false,
          error: result['userErrors'].map { |e| e['message'] }.join(', ')
        }
      end

      reservation = result['inventoryReservation']
      
      {
        success: true,
        reservation_id: reservation['id']
      }
      
    rescue => e
      Rails.logger.error "Erro ao criar reserva: #{e.message}"
      {
        success: false,
        error: e.message
      }
    end
  end

  def get_inventory_item_id(graphql_client, variant_id)
    query = <<~GRAPHQL
      query($variantId: ID!) {
        productVariant(id: $variantId) {
          inventoryItem {
            id
          }
        }
      }
    GRAPHQL

    variables = {
      variantId: "gid://shopify/ProductVariant/#{variant_id}"
    }

    response = graphql_client.query(query: query, variables: variables)
    response.body.dig('data', 'productVariant', 'inventoryItem', 'id')
  end

  def cancel_inventory_reservations(graphql_client, reservations)
    reservations.each do |reservation|
      begin
        Rails.logger.info "Cancelando reserva #{reservation[:reservation_id]} para #{reservation[:sku]}"
        
        mutation = <<~GRAPHQL
          mutation($id: ID!) {
            inventoryUnreserve(id: $id) {
              userErrors {
                field
                message
              }
            }
          }
        GRAPHQL

        variables = { id: reservation[:reservation_id] }
        
        response = graphql_client.query(query: mutation, variables: variables)
        
        if response.body['errors'] || response.body.dig('data', 'inventoryUnreserve', 'userErrors')&.any?
          Rails.logger.error "Erro ao cancelar reserva #{reservation[:reservation_id]}"
        else
          Rails.logger.info "Reserva #{reservation[:reservation_id]} cancelada com sucesso"
        end
        
      rescue => e
        Rails.logger.error "Erro ao cancelar reserva #{reservation[:reservation_id]}: #{e.message}"
      end
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
    when 'online'
      {
        access_token: ENV.fetch('CHASE_ORDERS_TOKEN'),
        location_id: ENV.fetch('LOCATION_LOG'),
        location_name: 'Online Store'
      }
    else
      # Fallback para Lagoa Seca
      {
        access_token: ENV.fetch('LAGOA_SECA_TOKEN_APP'),
        location_id: ENV.fetch('LOCATION_LAGOA_SECA'),
        location_name: 'Lagoa Seca'
      }
    end
  end

  def create_shopify_session(access_token)
    ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
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

  def build_tags(location_name)
    tags = ["PDV", @order_pdv.store_type, @order_pdv.payment_method, @order_pdv.user.name, "SEDEX", "NAO_PAGO", "NAO_PROCESSADO", "ESTOQUE_RESERVADO", location_name]
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
