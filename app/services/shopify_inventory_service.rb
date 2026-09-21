# frozen_string_literal: true

class ShopifyInventoryService
  def self.update_inventory(product, location, quantity)
    new.update_inventory(product, location, quantity)
  end

  def self.list_locations
    new.list_locations
  end

  def self.check_inventory_level(product, location)
    new.check_inventory_level(product, location)
  end

  def self.available_quantities(location_id, inventory_item_ids)
    new.available_quantities(location_id, inventory_item_ids)
  end

  def self.adjust_available(**args)
    new.adjust_available(**args)
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

    query = <<~GRAPHQL
      query getInventoryLevels($inventoryItemId: ID!) {
        inventoryItem(id: $inventoryItemId) {
          id
          sku
          tracked
          requiresShipping
          inventoryLevels(first: 50) {
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

    variables = { inventoryItemId: inventory_item_gid(product.shopify_inventory_item_id) }

    client = graphql_client
    response = client.query(query: query, variables: variables)

    return { success: false, message: "Erro GraphQL: #{response.body['errors']}" } if response.body['errors']

    inventory_item = response.body.dig('data', 'inventoryItem')
    return { success: false, message: 'Inventory item não encontrado', tracked: false } if inventory_item.nil?

    inventory_levels = inventory_item.dig('inventoryLevels', 'edges') || []

    target = inventory_levels.find do |edge|
      edge.dig('node', 'location', 'id')&.split('/')&.last == location_id
    end

    return {
      success: false,
      message: "Produto não encontrado na location #{location}",
      tracked: inventory_item['tracked']
    } unless target

    quantities = get_inventory_quantities(
      inventory_item_numeric_id(product.shopify_inventory_item_id),
      location_id
    )

    {
      success: true,
      available: quantities[:available],
      on_hand: quantities[:on_hand],
      committed: quantities[:committed],
      incoming: quantities[:incoming],
      tracked: inventory_item['tracked'],
      requires_shipping: inventory_item['requiresShipping'],
      location_name: target.dig('node', 'location', 'name'),
      sku: inventory_item['sku']
    }
  rescue StandardError => e
    { success: false, message: e.message }
  end

  def get_inventory_quantities(inventory_item_id, location_id)
    client = rest_client
    response = client.get(path: "inventory_levels.json?inventory_item_ids=#{inventory_item_id}&location_ids=#{location_id}")

    inventory_levels = response.body['inventory_levels'] || []

    if inventory_levels.any?
      level = inventory_levels.first
      {
        available: level['available'],
        on_hand: level['available'],
        committed: 0,
        incoming: 0
      }
    else
      {
        available: 0,
        on_hand: 0,
        committed: 0,
        incoming: 0
      }
    end
  rescue StandardError
    {
      available: 0,
      on_hand: 0,
      committed: 0,
      incoming: 0
    }
  end

  # Disponível ("available") de vários itens numa location do Shopify, em lote.
  # Devolve { 'inventory_item_id' => quantidade }; item sem nível nessa location não aparece,
  # e item não rastreado vem com nil. Erros de rede/API sobem para quem chamou decidir.
  def available_quantities(location_id, inventory_item_ids)
    ids = Array(inventory_item_ids).map { |id| inventory_item_numeric_id(id) }.uniq
    ids.each_slice(50).each_with_object({}) do |slice, result|
      response = rest_client.get(path: 'inventory_levels.json',
                                 query: { inventory_item_ids: slice.join(','), location_ids: location_id, limit: 250 })
      (response.body['inventory_levels'] || []).each { |level| result[level['inventory_item_id'].to_s] = level['available'] }
    end
  end

  ADJUST_QUANTITIES_MUTATION = <<~GRAPHQL
    mutation inventoryAdjustQuantities($input: InventoryAdjustQuantitiesInput!) {
      inventoryAdjustQuantities(input: $input) {
        userErrors {
          field
          message
        }
        inventoryAdjustmentGroup {
          id
        }
      }
    }
  GRAPHQL

  # Ajusta (soma delta ao) disponível de vários itens numa location, deixando registro no histórico
  # do inventário do Shopify com o motivo e a referência. A operação é atômica: se um item for
  # recusado, nenhum é alterado. changes: [{ inventory_item_id:, delta: }] (delta negativo = retirada).
  # Devolve { success: true, adjustment_id: } ou { success: false, error: }.
  def adjust_available(location_id:, changes:, reason:, reference_uri:)
    variables = {
      input: {
        reason: reason,
        name: 'available',
        referenceDocumentUri: reference_uri,
        changes: changes.map do |change|
          { inventoryItemId: inventory_item_gid(change[:inventory_item_id]), locationId: "gid://shopify/Location/#{location_id}", delta: change[:delta] }
        end
      }
    }

    response = graphql_client.query(query: ADJUST_QUANTITIES_MUTATION, variables: variables)
    return { success: false, error: "Erro GraphQL: #{Array(response.body['errors']).map { |e| e.is_a?(Hash) ? e['message'] : e }.join(', ')}" } if response.body['errors'].present?

    payload = response.body.dig('data', 'inventoryAdjustQuantities') || {}
    user_errors = payload['userErrors']
    return { success: false, error: user_errors.map { |e| e['message'] }.join(', ') } if user_errors.present?

    { success: true, adjustment_id: payload.dig('inventoryAdjustmentGroup', 'id') }
  rescue StandardError => e
    { success: false, error: "Erro ao ajustar no Shopify: #{e.message}" }
  end

  def list_locations
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

    response = graphql_client.query(query:)
    response.body.dig('data', 'locations', 'edges') || []
  rescue StandardError
    []
  end

  def update_inventory(product, location, quantity)
    return { success: false, message: 'Produto sem shopify_inventory_item_id' } unless product.shopify_inventory_item_id.present?

    location_id = get_location_id(location)
    return { success: false, message: "Location ID não encontrado para #{location}" } if location_id.blank?

    current = check_inventory_level(product, location)

    if current[:success]
      return { success: true, message: 'Estoque já está correto na Shopify', already_correct: true } if current[:on_hand] == quantity
      return { success: false, message: "Produto #{product.sku} não está sendo rastreado na Shopify." } unless current[:tracked]
    end

    update_inventory_available(product, quantity, location_id, location)

    { success: true, message: 'Estoque atualizado com sucesso na Shopify' }
  rescue StandardError => e
    { success: false, message: "Erro ao atualizar Shopify: #{e.message}" }
  end

  private

  def graphql_client
    ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
  end

  def rest_client
    ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def inventory_item_gid(value)
    str = value.to_s
    return str if str.start_with?('gid://shopify/InventoryItem/')
    return "gid://shopify/InventoryItem/#{str}" if str.match?(/\A\d+\z/)
    return str if str.start_with?('gid://')

    "gid://shopify/InventoryItem/#{str}"
  end

  def inventory_item_numeric_id(value)
    str = value.to_s
    return str.split('/').last if str.start_with?('gid://')
    str
  end

  def get_location_id(location)
    Location.shopify_location_id(location)
  end

  def update_inventory_available(product, quantity, location_id, location)
    mutation = <<~GRAPHQL
      mutation inventorySetOnHandQuantities($input: InventorySetOnHandQuantitiesInput!) {
        inventorySetOnHandQuantities(input: $input) {
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    variables = {
      input: {
        reason: "correction",
        setQuantities: [
          {
            inventoryItemId: inventory_item_gid(product.shopify_inventory_item_id),
            locationId: "gid://shopify/Location/#{location_id}",
            quantity: quantity
          }
        ]
      }
    }

    response = graphql_client.query(query: mutation, variables: variables)

    errors = response.body.dig('data', 'inventorySetOnHandQuantities', 'userErrors')
    raise "Shopify error: #{errors.map { |e| e['message'] }.join(', ')}" if errors.present?

    update_local_stock_record(product, location, quantity)
  end

  def update_local_stock_record(product, location, quantity)
    field = "stock_#{location}"

    if product.respond_to?(field)
      product.update(field => quantity)
    end
  end
end