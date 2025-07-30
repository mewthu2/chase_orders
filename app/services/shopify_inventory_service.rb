class ShopifyInventoryService
  def self.update_inventory(product, location, quantity, reason = 'correction')
    new.update_inventory(product, location, quantity, reason)
  end
  
  def self.list_locations
    new.list_locations
  end
  
  def self.check_inventory_level(product, location)
    new.check_inventory_level(product, location)
  end
  
  def initialize
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )
  end
  
  def check_inventory_level(product, location)
    return { success: false, message: 'Produto sem shopify_inventory_item_id' } unless product.shopify_inventory_item_id.present?
    
    location_id = get_location_id(location)
    return { success: false, message: "Location ID não encontrado para #{location}" } if location_id.blank?
    
    begin
      # Query mais simples e direta
      query = <<~GRAPHQL
        query getInventoryLevels($inventoryItemId: ID!) {
          inventoryItem(id: $inventoryItemId) {
            id
            sku
            tracked
            requiresShipping
            inventoryLevels(first: 10) {
              edges {
                node {
                  id
                  location {
                    id
                    name
                  }
                }
              }
            }
          }
        }
      GRAPHQL
      
      variables = {
        inventoryItemId: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}"
      }
      
      Rails.logger.info "Checking inventory levels for #{product.sku}"
      Rails.logger.info "Query: #{query}"
      Rails.logger.info "Variables: #{variables.to_json}"
      
      client = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
      response = client.query(query: query, variables: variables)
      
      Rails.logger.info "Inventory levels response: #{response.body.to_json}"
      
      if response.body['errors']
        Rails.logger.error "GraphQL errors: #{response.body['errors']}"
        return { success: false, message: "Erro GraphQL: #{response.body['errors']}" }
      end
      
      inventory_item = response.body.dig('data', 'inventoryItem')
      
      if inventory_item.nil?
        Rails.logger.warn "Inventory item not found"
        return { 
          success: false, 
          message: 'Inventory item não encontrado',
          tracked: false
        }
      end
      
      # Procurar o nível de inventário para a location específica
      inventory_levels = inventory_item.dig('inventoryLevels', 'edges') || []
      target_level = nil
      all_locations = []
      
      inventory_levels.each do |edge|
        level = edge['node']
        level_location_id = level.dig('location', 'id')&.gsub('gid://shopify/Location/', '')
        location_name = level.dig('location', 'name')
        
        Rails.logger.info "Found inventory level for location #{location_name} (ID: #{level_location_id})"
        
        location_info = {
          location_name: location_name,
          location_id: level_location_id,
          inventory_level_id: level['id']
        }
        
        all_locations << location_info
        
        if level_location_id == location_id
          target_level = level
          Rails.logger.info "✅ Found target location: #{location_name}"
        end
      end
      
      if target_level.nil?
        Rails.logger.warn "No inventory level found for target location #{location_id}"
        Rails.logger.info "Available locations for this product:"
        all_locations.each do |loc|
          Rails.logger.info "  - #{loc[:location_name]} (ID: #{loc[:location_id]})"
        end
        
        return { 
          success: false, 
          message: "Produto não encontrado na location #{location} (ID: #{location_id}). Locations disponíveis: #{all_locations.map { |l| l[:location_name] }.join(', ')}",
          tracked: inventory_item['tracked'],
          all_locations: all_locations
        }
      end
      
      # Agora fazer uma query específica para obter as quantidades desta location
      quantities_result = get_inventory_quantities(product.shopify_inventory_item_id, location_id)
      
      {
        success: true,
        available: quantities_result[:available],
        on_hand: quantities_result[:on_hand],
        committed: quantities_result[:committed],
        incoming: quantities_result[:incoming],
        tracked: inventory_item['tracked'],
        requires_shipping: inventory_item['requiresShipping'],
        location_name: target_level.dig('location', 'name'),
        sku: inventory_item['sku']
      }
      
    rescue => e
      Rails.logger.error "Error checking inventory levels: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, message: e.message }
    end
  end
  
  def get_inventory_quantities(inventory_item_id, location_id)
    begin
      # Usar REST API para obter quantidades - mais confiável
      inventory_level_url = "inventory_levels.json?inventory_item_ids=#{inventory_item_id}&location_ids=#{location_id}"
      
      Rails.logger.info "Fetching inventory quantities via REST API: #{inventory_level_url}"
      
      client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
      response = client.get(path: inventory_level_url)
      
      Rails.logger.info "REST API response: #{response.body.to_json}"
      
      inventory_levels = response.body['inventory_levels'] || []
      
      if inventory_levels.any?
        level = inventory_levels.first
        Rails.logger.info "Found inventory level via REST:"
        Rails.logger.info "  - Available: #{level['available']}"
        
        {
          available: level['available'],
          on_hand: level['available'], # REST API só tem 'available'
          committed: 0, # Não disponível via REST
          incoming: 0   # Não disponível via REST
        }
      else
        Rails.logger.warn "No inventory levels found via REST API"
        {
          available: 0,
          on_hand: 0,
          committed: 0,
          incoming: 0
        }
      end
      
    rescue => e
      Rails.logger.error "Error getting inventory quantities: #{e.message}"
      {
        available: 0,
        on_hand: 0,
        committed: 0,
        incoming: 0
      }
    end
  end
  
  def list_locations
    begin
      query = <<~GRAPHQL
        query {
          locations(first: 20) {
            edges {
              node {
                id
                name
                address {
                  city
                  province
                }
              }
            }
          }
        }
      GRAPHQL
      
      client = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
      response = client.query(query: query)
      
      Rails.logger.info "Locations response: #{response.body.to_json}"
      
      locations = response.body.dig('data', 'locations', 'edges') || []
      
      locations.each do |edge|
        location = edge['node']
        location_id = location['id'].gsub('gid://shopify/Location/', '')
        Rails.logger.info "Location: #{location['name']} - ID: #{location_id} - City: #{location.dig('address', 'city')}"
      end
      
      locations
    rescue => e
      Rails.logger.error "Error listing locations: #{e.message}"
      []
    end
  end
  
  def update_inventory(product, location, quantity, reason = 'correction')
    Rails.logger.info "ShopifyInventoryService: Updating #{product.sku} to #{quantity} in #{location}"
    
    unless product.shopify_inventory_item_id.present?
      return { success: false, message: 'Produto sem shopify_inventory_item_id' }
    end
    
    location_id = get_location_id(location)
    if location_id.blank?
      return { success: false, message: "Location ID não encontrado para #{location}" }
    end
    
    Rails.logger.info "Using location_id: #{location_id} for location: #{location}"
    
    # PRIMEIRO: Verificar o estoque atual na Shopify
    Rails.logger.info "=== CHECKING CURRENT SHOPIFY INVENTORY ==="
    current_inventory = check_inventory_level(product, location)
    Rails.logger.info "Current inventory result: #{current_inventory}"
    
    if current_inventory[:success]
      Rails.logger.info "Current Shopify inventory:"
      Rails.logger.info "  - Available: #{current_inventory[:available]}"
      Rails.logger.info "  - On Hand: #{current_inventory[:on_hand]}"
      Rails.logger.info "  - Committed: #{current_inventory[:committed]}"
      Rails.logger.info "  - Tracked: #{current_inventory[:tracked]}"
      Rails.logger.info "  - Location: #{current_inventory[:location_name]}"
      
      # Verificar se o produto está sendo rastreado
      unless current_inventory[:tracked]
        return { 
          success: false, 
          message: "Produto #{product.sku} não está sendo rastreado na Shopify. Ative o rastreamento primeiro." 
        }
      end
      
      # Verificar se a quantidade já está correta
      if current_inventory[:on_hand] == quantity
        Rails.logger.warn "✅ Quantity is already correct in Shopify (#{current_inventory[:on_hand]} == #{quantity})"
        return { 
          success: true, 
          message: "Estoque já está correto na Shopify (#{quantity} unidades)",
          already_correct: true
        }
      end
      
      Rails.logger.info "🔄 Need to update: #{current_inventory[:on_hand]} -> #{quantity}"
    else
      Rails.logger.error "Failed to check current inventory: #{current_inventory[:message]}"
      
      # Se não conseguiu verificar, mas tem informações sobre outras locations
      if current_inventory[:all_locations]
        Rails.logger.info "Available locations for this product:"
        current_inventory[:all_locations].each do |loc|
          Rails.logger.info "  - #{loc[:location_name]} (ID: #{loc[:location_id]})"
        end
      end
      
      # Continuar com a atualização mesmo sem conseguir verificar
      Rails.logger.warn "Continuing with update despite verification failure..."
    end
    
    begin
      # Usar exatamente a mesma lógica do job que funciona
      update_inventory_quantity(product, quantity, location_id)
      
      Rails.logger.info "Shopify inventory updated successfully for #{product.sku}: #{quantity} units"
      
      # Verificar se realmente foi atualizado
      Rails.logger.info "=== VERIFYING UPDATE ==="
      updated_inventory = check_inventory_level(product, location)
      if updated_inventory[:success]
        Rails.logger.info "After update - On Hand: #{updated_inventory[:on_hand]}"
        if updated_inventory[:on_hand] == quantity
          Rails.logger.info "✅ Update confirmed in Shopify!"
        else
          Rails.logger.warn "⚠️ Update may not have worked. Expected: #{quantity}, Got: #{updated_inventory[:on_hand]}"
        end
      else
        Rails.logger.warn "Could not verify update: #{updated_inventory[:message]}"
      end
      
      # Atualizar registro local
      update_local_stock_record(product, location, quantity)
      
      { success: true, message: 'Estoque atualizado com sucesso na Shopify' }
      
    rescue StandardError => e
      Rails.logger.error "Error updating Shopify inventory for #{product.sku}: #{e.message}"
      Rails.logger.error "Error class: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, message: "Erro ao atualizar Shopify: #{e.message}" }
    end
  end
  
  private
  
  def get_location_id(location)
    location_id = case location
                  when 'lagoa_seca'
                    ENV.fetch('LOCATION_LAGOA_SECA', nil) # 72286994506
                  when 'bh_shopping'
                    ENV.fetch('LOCATION_BH_SHOPPING', nil) # 72286699594
                  when 'rj'
                    ENV.fetch('LOCATION_BARRA_SHOPPING', nil) # 72287027274
                  else
                    ENV.fetch('LOCATION_LAGOA_SECA', nil)
                  end
    
    Rails.logger.info "Location mapping: #{location} -> #{location_id}"
    location_id
  end
  
  # Método idêntico ao do job que funciona
  def update_inventory_quantity(product, quantity, location_id)
    mutation = <<~GRAPHQL
      mutation inventorySetOnHandQuantities($input: InventorySetOnHandQuantitiesInput!) {
        inventorySetOnHandQuantities(input: $input) {
          inventoryAdjustmentGroup {
            id
            createdAt
            reason
          }
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL
    
    input = {
      reason: 'correction',
      setQuantities: [
        {
          inventoryItemId: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}",
          locationId: "gid://shopify/Location/#{location_id}",
          quantity: quantity
        }
      ]
    }
    
    Rails.logger.info "GraphQL mutation: #{mutation}"
    Rails.logger.info "GraphQL input: #{input.to_json}"
    Rails.logger.info "=== CRITICAL DEBUG INFO ==="
    Rails.logger.info "Product SKU: #{product.sku}"
    Rails.logger.info "Inventory Item ID: #{product.shopify_inventory_item_id}"
    Rails.logger.info "Target Location ID: #{location_id}"
    Rails.logger.info "Target Quantity: #{quantity}"
    Rails.logger.info "Full Location GID: gid://shopify/Location/#{location_id}"
    Rails.logger.info "=========================="
    
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
    response = client.query(query: mutation, variables: { input: input })
    
    Rails.logger.info "GraphQL response: #{response.body.to_json}"
    
    user_errors = response.body.dig('data', 'inventorySetOnHandQuantities', 'userErrors') || []
    
    if response.body['errors'] || user_errors.any?
      error_msg = response.body['errors'] || user_errors
      Rails.logger.error "GraphQL error: #{error_msg}"
      raise StandardError, "Erro GraphQL: #{error_msg}"
    end
    
    # Verificar se houve adjustment group (como no job original)
    adjustment_group = response.body.dig('data', 'inventorySetOnHandQuantities', 'inventoryAdjustmentGroup')
    
    if adjustment_group
      Rails.logger.info "✅ Adjustment Group created: #{adjustment_group['id']}"
      Rails.logger.info "Created At: #{adjustment_group['createdAt']}"
      Rails.logger.info "Reason: #{adjustment_group['reason']}"
    else
      Rails.logger.warn "⚠️  NO ADJUSTMENT GROUP RETURNED!"
      Rails.logger.warn "This usually means:"
      Rails.logger.warn "1. The quantity is already correct"
      Rails.logger.warn "2. The location_id is wrong"
      Rails.logger.warn "3. The inventory_item_id is wrong"
      Rails.logger.warn "4. The product is not tracked at this location"
      
      # Não falhar aqui - pode ser que a quantidade já esteja correta
      Rails.logger.warn "Continuing anyway - will verify in post-update check"
    end
  end
  
  # Método idêntico ao do job que funciona
  def update_local_stock_record(product, location, quantity)
    case location
    when 'lagoa_seca'
      product.update(stock_lagoa_seca: quantity) if product.respond_to?(:stock_lagoa_seca)
      Rails.logger.info "Updated local stock_lagoa_seca for #{product.sku}: #{quantity}"
    when 'bh_shopping'
      product.update(stock_bh_shopping: quantity) if product.respond_to?(:stock_bh_shopping)
      Rails.logger.info "Updated local stock_bh_shopping for #{product.sku}: #{quantity}"
    when 'rj'
      product.update(stock_rj: quantity) if product.respond_to?(:stock_rj)
      Rails.logger.info "Updated local stock_rj for #{product.sku}: #{quantity}"
    end
  end
end
