class StockService
  ONLINE_STORE_LOCATION_NAME = 'Online Store'.freeze

  def self.check_stock(product_id, location)
    Rails.logger.info "StockService.check_stock | variant_id: #{product_id}, location: #{location}"

    begin
      product = Product.find_by(shopify_variant_id: product_id)

      unless product
        return {
          success: false,
          available_quantity: 0,
          location: location,
          message: 'Produto não encontrado'
        }
      end

      check_shopify_stock(product, location)
    rescue StandardError => e
      Rails.logger.error e.message
      {
        success: false,
        available_quantity: 0,
        location: location,
        message: e.message
      }
    end
  end

  def self.check_shopify_stock(product, location)
    config = ShopifyIntegrationService.get_store_config_static(location)

    unless config && config[:access_token].present? && config[:location_id].present?
      return {
        success: false,
        available_quantity: 0,
        location: location,
        message: "Configuração não encontrada para #{location}"
      }
    end

    session = ShopifyIntegrationService.create_shopify_session_static(config[:access_token])
    client = ShopifyAPI::Clients::Rest::Admin.new(session:)

    inventory_item_id = resolve_inventory_item_id(client, product)

    return {
      success: false,
      available_quantity: 0,
      location: config[:location_name],
      message: 'inventory_item_id não encontrado'
    } unless inventory_item_id

    response = client.get(path: 'inventory_levels.json', query: {
      inventory_item_ids: inventory_item_id,
      location_ids: config[:location_id]
    })

    inventory = response.body['inventory_levels']

    if inventory&.any?
      available = inventory.first['available'].to_i

      {
        success: true,
        available_quantity: available,
        location: config[:location_name]
      }
    else
      {
        success: false,
        available_quantity: 0,
        location: config[:location_name],
        message: 'Sem estoque nessa location'
      }
    end
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