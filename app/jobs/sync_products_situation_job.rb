class SyncProductsSituationJob < ActiveJob::Base
  SHOPIFY_LOCATION_IDS = {
    lagoa_seca: ENV.fetch('LOCATION_LAGOA_SECA'),
    bh_shopping: ENV.fetch('LOCATION_BH_SHOPPING'),
    rj: ENV.fetch('LOCATION_BARRA_SHOPPING')
  }.freeze

  BATCH_SIZE = 200

  def perform
    sync_tiny_products
    sync_shopify_products
    sync_shopify_fields
    sync_shopify_inventory_by_location
  end

  def sync_tiny_products
    SHOPIFY_LOCATION_IDS.each_key do |location|
      Tiny::Products.list_all_products(location.to_s, '', 'update_products_situation', '')
    end
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_shopify_fields
    %w[shopify_product_id price_and_title].each do |action|
      Shopify::Products.sync_shopify_data_on_product(action)
    end
  end

  def sync_shopify_inventory_by_location
    SHOPIFY_LOCATION_IDS.each do |tiny_location, shopify_location_id|
      update_inventory_for_location(tiny_location, shopify_location_id)
    end
  end

  private

  def update_inventory_for_location(tiny_location, shopify_location_id)
    stock_field = :"stock_#{tiny_location}"

    Product.where.not(shopify_inventory_item_id: nil)
           .where("#{stock_field} IS NOT NULL")
           .in_batches(of: BATCH_SIZE) do |batch|

      quantities = batch.map do |product|
        {
          inventoryItemId: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}",
          locationId: "gid://shopify/Location/#{shopify_location_id}",
          quantity: product.send(stock_field).to_i
        }
      end

      update_inventory_items_batch(quantities)
    end
  end

  def update_inventory_items_batch(quantities)
    return if quantities.empty?

    mutation = <<~GRAPHQL
      mutation($input: InventorySetQuantitiesInput!) {
        inventorySetQuantities(input: $input) {
          inventoryAdjustmentGroup {
            id
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
        ignoreCompareQuantity: true,
        reason: 'stock sync',
        quantities:
      }
    }

    session = ShopifyAPI::Context.active_session

    begin
      client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
      response = client.query(query: mutation, variables:)

      if response.body['errors'].present?
        Rails.logger.error "Error updating inventory batch: #{response.body['errors']}"
      end
    rescue StandardError => e
      Rails.logger.error "Error updating inventory batch: #{e.message}"
    end
  end
end