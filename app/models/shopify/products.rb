module Shopify::Products
  require 'shopify_api'
  include ApplicationHelper

  module_function

  def client_shopify_graphql
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
    ShopifyAPI::Clients::Graphql::Admin.new(session:)
  end

  def client_shopify_rest
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
    )
    ShopifyAPI::Clients::Rest::Admin.new(session:)
  end

  def sync_shopify_data_on_product(function)
    sync_methods = {
      'shopify_product_id' => method(:update_product_with_shopify_id),
      'price_and_title' => method(:update_product_with_price_and_title),
      'variant_id' => method(:update_product_with_variant_id),
      'cost' => method(:update_product_variant_cost)
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
    rescue StandardError => e
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
    rescue StandardError => e
      puts "Erro ao buscar o produto #{product.sku}: #{e.message}"
    end
  end

  def update_product_variant_cost(product)
    return unless product.shopify_inventory_item_id.present?

    unless product.cost.to_f.positive?
      Rails.logger.info "Custo inválido ou zero para #{product.sku}. Nenhuma atualização realizada."
      return
    end

    query = <<~GRAPHQL
      mutation($id: ID!, $input: InventoryItemInput!) {
        inventoryItemUpdate(id: $id, input: $input) {
          inventoryItem {
            id
            unitCost {
              amount
            }
          }
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    variables = {
      id: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}",
      input: {
        cost: product.cost.to_f,
        tracked: true,
        countryCodeOfOrigin: 'BR'
      }
    }

    begin
      response = client_shopify_graphql.query(
        query:,
        variables:
      )

      if response.body['errors']
        Rails.logger.error "Erro GraphQL: #{response.body['errors']}"
      elsif user_errors == response.body.dig('data', 'inventoryItemUpdate', 'userErrors').presence
        Rails.logger.error "Erros na mutation: #{user_errors}"
      else
        updated_cost = response.body.dig('data', 'inventoryItemUpdate', 'inventoryItem', 'unitCost', 'amount')
        Rails.logger.info "Custo atualizado para #{updated_cost} no item de inventário #{product.shopify_inventory_item_id}"
      end

    rescue StandardError => e
      Rails.logger.error "Erro ao processar #{product.sku}: #{e.message}\n#{e.backtrace.join("\n")}"
    end
  end

  def update_product_with_variant_id(product)
    query = <<~GRAPHQL
      query inventoryItem {
        inventoryItem(id: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}") {
          id
          variant {
            id
            sku
          }
        }
      }
    GRAPHQL

    begin
      response = client_shopify_graphql.query(query:)

      if response.body['data'].present? && response.body['data']['inventoryItem'].present?
        variant_gid = response.body['data']['inventoryItem']['variant']['id']

        variant_id = variant_gid.match(/ProductVariant\/(\d+)/)&.[](1)

        if variant_id
          product.update(shopify_variant_id: variant_id)
          puts "Atualizado produto #{product.sku} com Variant ID: #{variant_id}"
        else
          puts "Variant ID não extraído corretamente para o produto #{product.sku}"
        end
      else
        puts "Nenhuma correspondência encontrada para o produto #{product.sku}"
      end
    rescue StandardError => e
      puts "Erro ao buscar o variant_id do produto #{product.sku}: #{e.message}"
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

  def search_inventory_item_info(inventory_item_ids)
    client_shopify_rest.get(path: 'inventory_items', query: { ids: inventory_item_ids })
  end

  def update_or_create_by_product_data(products)
    products.each do |shopify_product_data|
      shopify_product_data['variants'].each do |variant_data|
        product = Product.find_or_initialize_by(sku: variant_data['sku'])

        product.assign_attributes(
          shopify_product_name: shopify_product_data['title'],
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
    existing_products = Product.where(sku: inventory_items.map { |i| i['sku'] }).index_by(&:sku)

    inventory_items.each do |item_data|
      product = existing_products[item_data['sku']] || Product.new(sku: item_data['sku'])

      next if product.persisted? &&
        product.shopify_inventory_item_id == item_data['id'].to_s &&
        product.cost == item_data['cost'] &&
        product.sku == item_data['sku']

      product.assign_attributes(
        shopify_inventory_item_id: item_data['id'],
        sku: item_data['sku']
      )

      product.save!
    end
  end

  def update_inventory_for_location(tiny_location, shopify_location_id)
    stock_field = :"stock_#{tiny_location}"

    products = Product.where.not(shopify_inventory_item_id: nil)
                      .where("#{stock_field} IS NOT NULL")

    access_token = case tiny_location
                   when 'bh_shopping'
                     ENV.fetch('BH_SHOPPING_TOKEN_APP')
                   when 'rj'
                     ENV.fetch('BARRA_SHOPPING_TOKEN_APP')
                   when 'lagoa_seca'
                     ENV.fetch('LAGOA_SECA_TOKEN_APP')
                   else
                     raise "Token não definido para a localização: #{tiny_location}"
                   end

    products.each do |product|
      inventory_item_id = "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}"
      location_id = "gid://shopify/Location/#{shopify_location_id}"
      quantity = product.send(stock_field).to_i

      update_inventory_quantity(
        access_token,
        inventory_item_id:,
        location_id:,
        quantity:
      )
    end
  end

  def update_inventory_quantity(access_token, inventory_item_id:, location_id:, quantity:)
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
        name: 'available',
        reason: 'correction',
        ignoreCompareQuantity: true,
        quantities: [
          {
            inventoryItemId: inventory_item_id,
            locationId: location_id,
            quantity:
          }
        ]
      }
    }

    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token:
    )

    begin
      client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
      response = client.query(query: mutation, variables:)

      if response.body['errors'].present?
        Rails.logger.error "GraphQL error: #{response.body['errors']}"
        puts 'Erro ao atualizar o produto'
      elsif response.body.dig('data', 'inventorySetQuantities', 'userErrors').present?
        Rails.logger.error "User error: #{response.body.dig('data', 'inventorySetQuantities', 'userErrors')}"
        puts 'Erro do usuário ao atualizar o produto'
      else
        putss 'Produto atualizado com sucesso'
      end
    rescue StandardError => e
      Rails.logger.error "Exception: #{e.message}"
      puts 'Erro de exceção ao atualizar o produto'
    end
  end
end