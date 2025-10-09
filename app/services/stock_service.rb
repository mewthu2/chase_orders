class StockService
  def self.check_stock(product_id, quantity, store_type)
    Rails.logger.info "StockService.check_stock called with product_id: #{product_id}, quantity: #{quantity}, store: #{store_type}"
    
    begin
      product = Product.find_by(shopify_variant_id: product_id)
      
      unless product
        Rails.logger.warn "Product with variant_id #{product_id} not found in local database"
        return {
          success: false,
          has_sufficient_stock: false,
          available_quantity: 0,
          location: get_location_name(store_type),
          message: "Produto não encontrado"
        }
      end
      
      Rails.logger.info "Found product in local database: #{product.sku}"
      
      return check_shopify_stock(product, quantity, store_type)
      
    rescue => e
      Rails.logger.error "Error in StockService.check_stock: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: get_location_name(store_type),
        message: "Erro ao verificar estoque: #{e.message}"
      }
    end
  end
  
  private

  def self.check_shopify_stock(product, quantity, store_type)
    Rails.logger.info "Checking Shopify stock for product #{product.sku} in store #{store_type}"

    begin
      config = ShopifyIntegrationService.get_store_config_static(store_type)
      Rails.logger.info "Using location: #{config[:location_name]} (ID: #{config[:location_id]})"
      
      session = ShopifyIntegrationService.create_shopify_session_static(config[:access_token])
      client = ShopifyAPI::Clients::Rest::Admin.new(session: session)
      
      unless product.shopify_inventory_item_id.present?
        Rails.logger.warn "Product #{product.sku} missing shopify_inventory_item_id, fetching from variant"
        
        variant_response = client.get(path: "variants/#{product.shopify_variant_id}.json")
        variant = variant_response.body['variant']
        
        if variant && variant['inventory_item_id']
          inventory_item_id = variant['inventory_item_id']
          Rails.logger.info "Found inventory_item_id: #{inventory_item_id} for variant #{product.shopify_variant_id}"
          
          if product.shopify_inventory_item_id.blank?
            product.update(shopify_inventory_item_id: inventory_item_id)
          end
        else
          Rails.logger.error "Could not find inventory_item_id for variant #{product.shopify_variant_id}"
          return {
            success: false,
            has_sufficient_stock: false,
            available_quantity: 0,
            location: config[:location_name],
            message: "Não foi possível obter informações de inventário"
          }
        end
      else
        inventory_item_id = product.shopify_inventory_item_id
      end
      
      Rails.logger.info "Checking inventory for item_id: #{inventory_item_id} at location: #{config[:location_id]}"
      
      inventory_response = client.get(path: "inventory_levels.json", query: { 
        inventory_item_ids: inventory_item_id,
        location_ids: config[:location_id]
      })
      
      inventory_levels = inventory_response.body['inventory_levels']
      Rails.logger.info "Inventory API response: #{inventory_levels.inspect}"
      
      if inventory_levels && inventory_levels.any?
        inventory_level = inventory_levels.first
        available_quantity = inventory_level['available'] || 0
        
        Rails.logger.info "Stock found for #{product.sku} at #{config[:location_name]}: #{available_quantity}"
        
        has_sufficient_stock = available_quantity >= quantity.to_i
        
        {
          success: true,
          has_sufficient_stock: has_sufficient_stock,
          available_quantity: available_quantity,
          location: config[:location_name],
          message: has_sufficient_stock ? "Estoque disponível" : "Estoque insuficiente"
        }
      else
        Rails.logger.warn "No inventory levels found for #{product.sku} at location #{config[:location_id]}"
        
        all_locations_response = client.get(path: "inventory_levels.json", query: { 
          inventory_item_ids: inventory_item_id
        })
        
        all_levels = all_locations_response.body['inventory_levels']
        Rails.logger.info "All locations inventory for #{product.sku}: #{all_levels.inspect}"
        
        {
          success: false,
          has_sufficient_stock: false,
          available_quantity: 0,
          location: config[:location_name],
          message: "Produto não disponível nesta localização"
        }
      end
      
    rescue => e
      Rails.logger.error "Error checking Shopify stock: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      {
        success: false,
        has_sufficient_stock: false,
        available_quantity: 0,
        location: get_location_name(store_type),
        message: "Erro ao verificar estoque: #{e.message}"
      }
    end
  end

  def self.get_location_name(store_type)
    case store_type
    when 'lagoa_seca'
      'Lagoa Seca'
    when 'bh_shopping'
      'BH Shopping'
    when 'rj'
      'Barra Shopping (RJ)'
    when 'eldorado_sp'
      'Eldorado SP'
    when 'fortaleza_rio_mar'
      'Fortaleza Rio Mar'
    when 'porto_alegre_bourbon'
      'Porto Alegre Bourbon'
    when 'online'
      'Online Store'
    else
      'Loja Desconhecida'
    end
  end
end
