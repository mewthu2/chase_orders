class Shopify::Products
  require 'shopify_api'

  class << self
    def list_all_products(function)
      response = client_shopify_rest.get(path: 'products', query: { limit: 150 })
      process_inventory_items(response)

      case function
      when 'create_update_shopify_products'
        loop do
          next_page_info = response.next_page_info
          break unless next_page_info

          response = client_shopify_rest.get(path: 'products', query: { limit: 150, page_info: next_page_info })
          process_inventory_items(response)
        end
      end
    end

    def process_inventory_items(response)
      inventory_item_ids = []

      return unless response.body.key?('products')
      response.body['products'].each do |product|
        next unless product['variants'].present?
        product['variants'].each do |variant|
          inventory_item_ids << variant['inventory_item_id']
        end
      end

      inventory_items_response = search_inventory_item_info(inventory_item_ids.join(','))
      find_or_create_product(inventory_items_response.body['inventory_items'])

      loop do
        next_page_info = inventory_items_response.next_page_info
        break unless next_page_info

        inventory_items_response = client_shopify_rest.get(path: 'inventory_items', query: { page_info: next_page_info })
        find_or_create_product(inventory_items_response.body['inventory_items'])
      end
    end

    private

    def search_inventory_item_info(inventory_item_ids)
      client_shopify_rest.get(path: 'inventory_items', query: { ids: inventory_item_ids })
    end

    def client_shopify_rest
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('SHOPIFY_TOKEN')
      )
      ShopifyAPI::Clients::Rest::Admin.new(session:)
    end

    def find_or_create_product(inventory_items)
      inventory_items.each do |shopify_inventory_item_data|
        product = Product.find_by(sku: shopify_inventory_item_data['sku'])

        next unless product.present?

        product.update(shopify_inventory_item_id: shopify_inventory_item_data['id'],
                       cost: shopify_inventory_item_data['cost'])
      end
    end
  end
end
