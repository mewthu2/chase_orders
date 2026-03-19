class StockService
  ONLINE_STORE_LOCATION_NAME = 'Online Store'.freeze

  def self.check_stock(product_id, quantity)
    Rails.logger.info "StockService.check_stock | variant_id: #{product_id}, quantity: #{quantity}"

    begin
      product = Product.find_by(shopify_variant_id: product_id)

      unless product
        Rails.logger.warn "Produto não encontrado na base local: #{product_id}"
        return {
          success: false,
          has_sufficient_stock: false,
          available_quantity: 0,
          location: ONLINE_STORE_LOCATION_NAME,
          message: 'Produto não encontrado'
        }
      end

      check_shopify_stock(product, quantity)
    rescue StandardError => e
      Rails.logger.error "Erro em StockService.check_stock: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: ONLINE_STORE_LOCATION_NAME,
        message: "Erro ao verificar estoque: #{e.message}"
      }
    end
  end

  def self.check_shopify_stock(product, quantity)
    config = ShopifyIntegrationService.get_store_config_static('online')

    unless config && config[:access_token].present? && config[:location_id].present?
      Rails.logger.error "Configuração da Online Store incompleta: #{config.inspect}"
      return {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: ONLINE_STORE_LOCATION_NAME,
        message: 'Configuração da Online Store não encontrada. Verifique as variáveis ONLINE_STORE_TOKEN_APP e LOCATION_ONLINE_STORE.'
      }
    end

    location_name = config[:location_name] || ONLINE_STORE_LOCATION_NAME
    Rails.logger.info "Verificando estoque de #{product.sku} na #{location_name} (location_id: #{config[:location_id]})"

    session = ShopifyIntegrationService.create_shopify_session_static(config[:access_token])
    client = ShopifyAPI::Clients::Rest::Admin.new(session:)

    inventory_item_id = resolve_inventory_item_id(client, product)

    unless inventory_item_id
      return {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: location_name,
        message: 'Não foi possível obter o inventory_item_id do produto'
      }
    end

    Rails.logger.info "inventory_item_id: #{inventory_item_id} | location_id: #{config[:location_id]}"

    inventory_response = client.get(path: 'inventory_levels.json', query: {
      inventory_item_ids: inventory_item_id,
      location_ids: config[:location_id]
    })

    inventory_levels = inventory_response.body['inventory_levels']
    Rails.logger.info "inventory_levels: #{inventory_levels.inspect}"

    if inventory_levels&.any?
      available_quantity = inventory_levels.first['available'].to_i
      has_sufficient_stock = available_quantity >= quantity.to_i

      Rails.logger.info "Estoque de #{product.sku} na #{location_name}: #{available_quantity} (solicitado: #{quantity})"

      {
        success: true,
        has_sufficient_stock:,
        available_quantity:,
        location: location_name,
        message: has_sufficient_stock ? 'Estoque disponível' : "Estoque insuficiente. Disponível: #{available_quantity}"
      }
    else
      Rails.logger.warn "Nenhum nível de estoque encontrado para #{product.sku} na location #{config[:location_id]}"
      {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: location_name,
        message: 'Produto não disponível na Online Store'
      }
    end
  rescue StandardError => e
    Rails.logger.error "Erro ao verificar estoque na Shopify: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    {
      success: false,
      has_sufficient_stock: false,
      available_quantity: 0,
      location: ONLINE_STORE_LOCATION_NAME,
      message: "Erro ao verificar estoque: #{e.message}"
    }
  end

  def self.resolve_inventory_item_id(client, product)
    if product.shopify_inventory_item_id.present?
      Rails.logger.info "Usando shopify_inventory_item_id já salvo: #{product.shopify_inventory_item_id}"
      return product.shopify_inventory_item_id
    end

    Rails.logger.info "Buscando inventory_item_id via API para variant #{product.shopify_variant_id}"
    variant_response = client.get(path: "variants/#{product.shopify_variant_id}.json")
    variant = variant_response.body['variant']

    inventory_item_id = variant&.dig('inventory_item_id')

    if inventory_item_id.present?
      Rails.logger.info "inventory_item_id encontrado: #{inventory_item_id}. Salvando no produto."
      product.update_column(:shopify_inventory_item_id, inventory_item_id)
    else
      Rails.logger.error "inventory_item_id não encontrado para variant #{product.shopify_variant_id}"
    end

    inventory_item_id
  rescue StandardError => e
    Rails.logger.error "Erro ao buscar inventory_item_id: #{e.message}"
    nil
  end
end