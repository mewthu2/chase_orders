class Shopify::Products
  require 'shopify_api'

  class << self
    def sync_shopify_data_on_product(function)
      sync_methods = {
        'shopify_product_id' => method(:update_product_with_shopify_id),
        'price_and_title' => method(:update_product_with_price_and_title)
      }

      if sync_methods.key?(function)
        Product.find_each(batch_size: 100) do |product|
          sync_methods[function].call(product)
        end
      else
        puts "Função não reconhecida: #{function}"
      end
    end

    def update_product_with_price_and_title(product)
      query = <<~GRAPHQL
        query inventoryItem {
          inventoryItem(id: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}") {
            id
            tracked
            sku
            variant {
              id
              price
              compareAtPrice
              product {
                title
              }
            }
          }
        }
      GRAPHQL

      begin
        response = client_shopify_graphql.query(query:)

        if response.body['data'].present? && response.body['data']['inventoryItem'].present?
          price = response.body['data']['inventoryItem']['variant']['price']
          product_name = response.body['data']['inventoryItem']['variant']['product']['title']

          if price
            product.update(price:, shopify_product_name: product_name)
            puts "Atualizado produto #{product.sku} com o preço: #{price} e nome: #{product_name}"
          else
            puts "Preço não encontrado para o produto #{product.sku}"
          end
        else
          puts "Nenhuma correspondência encontrada para o produto #{product.sku}"
        end
      rescue => e
        puts "Erro ao buscar o preço do produto #{product.sku}: #{e.message}"
      end
    end
    

    def update_product_with_shopify_id(product)
      query = <<-GRAPHQL
        {
          products(first: 1, query: "sku:#{product.sku}") {
            edges {
              node {
                id
                title
                variants(first: 10) {
                  edges {
                    node {
                      sku
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      begin
        response = client_shopify_graphql.query(query:)
        if response.body['data'].present? && response.body['data']['products']['edges'].any?
          shopify_product_id = extract_shopify_product_id(response.body)
          if shopify_product_id
            product.update(shopify_product_id:)
            puts "Atualizado produto #{product.sku} com Shopify ID: #{shopify_product_id}"
          else
            puts "Shopify ID não encontrado para o produto #{product.sku}"
          end
        else
          puts "Nenhuma correspondência encontrada para o produto #{product.sku}"
        end
      rescue => e
        puts "Erro ao buscar o produto #{product.sku}: #{e.message}"
      end
    end

    def extract_shopify_product_id(response_body)
      product_edge = response_body['data']['products']['edges'].first
      return unless product_edge

      product_edge['node']['id'].match(/\d+$/)[0] if product_edge['node']['id'].present?
    end

    def list_all_products(function)
      response = client_shopify_rest.get(path: 'products', query: { limit: 150 })
      process_inventory_items(response)

      case function
      when 'create_update_shopify_products'
        loop do
          next_page_info = response.next_page_info
          break unless next_page_info

          response = client_shopify_rest.get(path: 'products', query: { limit: 150, page_info: next_page_info })

          update_or_create_by_product_data(response.body['products'])

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
      update_or_create_by_inventory_data(inventory_items_response.body['inventory_items'])

      loop do
        next_page_info = inventory_items_response.next_page_info
        break unless next_page_info

        inventory_items_response = client_shopify_rest.get(path: 'inventory_items', query: { page_info: next_page_info })
        update_or_create_by_inventory_data(inventory_items_response.body['inventory_items'])
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

    def client_shopify_graphql
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('SHOPIFY_TOKEN')
      )
      ShopifyAPI::Clients::Graphql::Admin.new(session:)
    end

    def update_or_create_by_product_data(products)
      products.each do |shopify_product_data|
        shopify_product_data['variants'].each do |variant_data|
          product = Product.find_or_initialize_by(sku: variant_data['sku'])

          product.assign_attributes(
            shopify_product_name: shopify_product_data['title'],
            cost: variant_data['cost'],
            sku: variant_data['sku'],
            price: variant_data['price'],
            option1: variant_data['option1'],
            option2: variant_data['option2'],
            option3: variant_data['option3'],
            compare_at_price: variant_data['compare_at_price'],
            vendor: shopify_product_data['vendor'],
            tags: shopify_product_data['tags'],
            created_at: variant_data['created_at'],
            updated_at: variant_data['updated_at']
          )

          product.save!
        end
      end
    end

    def update_or_create_by_inventory_data(inventory_items)
      inventory_items.each do |shopify_inventory_item_data|
        product = Product.find_or_initialize_by(sku: shopify_inventory_item_data['sku'])

        product.update(shopify_inventory_item_id: shopify_inventory_item_data['id'],
                       cost: shopify_inventory_item_data['cost'],
                       sku: shopify_inventory_item_data['sku'],
                       created_at: shopify_inventory_item_data['created_at'],
                       updated_at: shopify_inventory_item_data['updated_at'])
      end
    end
  end
end
