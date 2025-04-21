class Shopify::Orders
  require 'shopify_api'
  extend ApplicationHelper

  class << self
    def build_shopify_order(retorno)
      query = <<~QUERY
        mutation OrderCreate($order: OrderCreateOrderInput!, $options: OrderCreateOptionsInput) {
          orderCreate(order: $order, options: $options) {
            userErrors {
              field
              message
            }
            order {
              id
              totalTaxSet {
                shopMoney {
                  amount
                  currencyCode
                }
              }
              lineItems(first: 5) {
                nodes {
                  variant {
                    id
                  }
                  id
                  title
                  quantity
                  taxLines {
                    title
                    rate
                    priceSet {
                      shopMoney {
                        amount
                        currencyCode
                      }
                    }
                  }
                }
              }
            }
          }
        }
      QUERY

      variables = {
        order: {
          currency: 'BRL',
          lineItems: retorno['pedido']['itens'].map do |item|
            {
              'title' => item['item']['descricao'],
              'priceSet' => { 'shopMoney' => { 'amount' => item['item']['valor_unitario'], 'currencyCode' => 'EUR' } },
              'quantity' => item['item']['quantidade'],
              'taxLines' => [
                {
                  'priceSet' => { 'shopMoney' => { 'amount' => '13.5', 'currencyCode' => 'EUR' } },
                  'rate' => 0.06,
                  'title' => 'State tax'
                }
              ]
            }
          end,
          'transactions' => [
            {
              'kind' => 'SALE',
              'status' => 'SUCCESS',
              'amountSet' => { 'shopMoney' => { 'amount' => retorno['pedido']['total_pedido'], 'currencyCode' => 'BRL' } }
            }
          ]
        }
      }

      client_shopify_graphql.query(query:, variables:)
    end
    
    def find_product_id_by_sku_graphql(client, sku)
      return nil if sku.empty?
    
      query = <<~GRAPHQL
        query {
          productVariants(first: 1, query: "sku:#{sku}") {
            edges {
              node {
                id
              }
            }
          }
        }
      GRAPHQL
    
      response = client.query(query: query)
      variant = response.body.dig('data', 'productVariants', 'edges', 0, 'node')
      variant ? variant['id'] : nil
    rescue => e
      puts "Erro ao buscar produto por SKU: #{e.message}"
      nil
    end

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

    def build_shopify_order_rest(kind, response)
      case kind
      when 'bh_shopping'
        location_id = 72286699594
      end

      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
      )

      pedido = response['pedido']
      cliente = pedido['cliente']

      order = ShopifyAPI::Order.new(session:)

      # Build line items
      order.line_items = pedido['itens'].map do |item|
        sku = item.dig('item', 'codigo') || ''
        product_id = find_product_id_by_sku(session, sku)

        {
          'title' => item.dig('item', 'descricao') || 'Produto sem nome',
          'price' => item.dig('item', 'valor_unitario').to_f,
          'grams' => (item.dig('item', 'peso_bruto') || 0).to_f * 1000,
          'quantity' => item.dig('item', 'quantidade').to_i,
          'sku' => sku,
          'product_id' => product_id,
          'tax_lines' => [{
            'price' => 0,
            'rate' => 0,
            'title' => 'Tax'
          }]
        }.compact
      end

      order.transactions = [
        {
          'kind' => 'sale',
          'status' => 'success',
          'amount' => pedido['total_produtos'].to_f,
          'gateway' => pedido['meio_pagamento'] || 'Sipay'
        }
      ]

      # Prepare customer data
      nome_completo = cliente['nome'] || 'Cliente Shopify'
      nomes = nome_completo.strip.split
      first_name = nomes.first
      last_name = nomes[1..].join(' ') if nomes.size > 1

      # Generate unique phone number
      customer_phone = if cliente['fone'].present?
                        generate_unique_phone(cliente['fone'], session)
                      else
                        generate_unique_phone(nil, session)
                      end

      # Build customer
      order.customer = {
        'first_name' => first_name || 'Cliente',
        'last_name' => last_name || '',
        'email' => cliente['email'].present? ? cliente['email'] : "sememail_#{SecureRandom.hex(4)}@dominiofalso.com",
        'phone' => customer_phone,
        'tax_exempt' => false,
        'addresses' => [build_address(cliente, customer_phone)],
        'default_address' => build_address(cliente, customer_phone)
      }

      # Build address
      endereco = build_address(cliente, customer_phone)
      order.shipping_address = endereco
      order.billing_address = endereco

      # Set order details

      order.total_tax = 0
      order.subtotal_price = pedido['total_produtos'].to_f
      order.total_price = pedido['total_produtos'].to_f
      order.currency = 'BRL'
      order.note = pedido['obs'] || ''
      order.closed_at = format_date(pedido['data_pedido']) || Time.now.iso8601
      order.created_at = format_date(pedido['data_pedido']) || Time.now.iso8601
      order.processed_at = format_date(pedido['data_pedido']) || Time.now.iso8601

      order.email = cliente['email'].present? ? cliente['email'] : "sememail_#{SecureRandom.hex(4)}@dominiofalso.com"
      order.phone = customer_phone

      # Definir fulfillment status e data
      fulfillment_date = format_date(pedido['data_pedido']) || Time.now.iso8601
      if pedido['situacao'] == 'Entregue'
        order.fulfillment_status = 'fulfilled'
        # Adicionar informações de fulfillment com a data do pedido
        order.fulfillments = [{
          'status' => 'success',
          'created_at' => fulfillment_date,
          'updated_at' => fulfillment_date
        }]
      else
        order.fulfillment_status = nil
      end

      order.location_id = location_id
      order.financial_status = 'paid'
      order.tags = pedido['marcadores'].join(', ') if pedido['marcadores'].present?

      # Add shipping if applicable
      if pedido['valor_frete'].to_f.positive?
        order.shipping_lines = [
          {
            'price' => pedido['valor_frete'].to_f,
            'title' => pedido['forma_envio'] == 'S' ? 'Sedex' : 'Frete padrão',
            'code' => pedido['codigo_rastreamento'] || '',
            'source' => 'external'
          }
        ]
      end

      retry_count = 0
      begin
        order.save!
        puts "Pedido criado com sucesso: #{order.id}"
        order
      rescue ShopifyAPI::Errors::HttpResponseError => e
        if e.response.body.include?('customer.phone') && retry_count < 3
          retry_count += 1
          order.customer['phone'] = generate_unique_phone(nil, session)
          retry
        else
          puts "Erro ao criar pedido: #{e.message}"
          puts "Detalhes: #{e.response.body}"
          nil
        end
      rescue StandardError => e
        puts "Erro inesperado: #{e.message}"
        puts e.backtrace.join("\n")
        nil
      end
    end

    def build_address(cliente, phone = nil)
      phone ||= format_phone_number(cliente['fone'])

      {
        'address1' => [cliente['endereco'], cliente['numero']].compact.join(', '),
        'address2' => cliente['complemento'] || '',
        'city' => cliente['cidade'] || 'Cidade não informada',
        'province' => cliente['uf'] || 'SP',
        'country' => 'BR',
        'zip' => cliente['cep']&.gsub(/\D/, '') || '00000000',
        'first_name' => cliente['nome'].split.first,
        'last_name' => cliente['nome'].split[1..].join(' '),
        'phone' => phone,
        'company' => cliente['nome_fantasia'] || ''
      }
    end

    def format_date(date_str)
      return Time.now.iso8601 if date_str.nil? || date_str.empty?

      begin
        if date_str.match(%r{\d{2}/\d{2}/\d{4}})
          DateTime.strptime("#{date_str} 12:00:00", '%d/%m/%Y %H:%M:%S').iso8601
        else
          Time.parse(date_str).iso8601
        end
      rescue ArgumentError
        Time.now.iso8601
      end
    end

    def generate_unique_phone(original_phone, session)
      base_phone = if original_phone.present?
                     format_phone_number(original_phone)
                   else
                     '+5511999999999'
                   end

      return base_phone if phone_unique?(base_phone, session)

      3.times do |i|
        unique_phone = if base_phone.end_with?('9')
                         base_phone.gsub(/(\d{2})$/, (i + 1).to_s.rjust(2, '0'))
                       else
                         "#{base_phone}#{i + 1}"
                       end

        return unique_phone if phone_unique?(unique_phone, session)
      end

      "+55119#{SecureRandom.rand(100000000..999999999)}"
    end

    def phone_unique?(phone, session)
      return false unless phone.present?

      customers = ShopifyAPI::Customer.all(
        session:,
        phone:,
        limit: 1
      )

      customers.empty?
    rescue
      false
    end

    def format_phone_number(phone)
      return nil unless phone.present?

      cleaned = phone.gsub(/\D/, '')

      case cleaned.size
      when 11, 10 then "+55#{cleaned}"
      when 8 then "+5511#{cleaned}"
      else "+55#{cleaned}"
      end
    end

    def find_product_id_by_sku(session, sku)
      query = <<~GRAPHQL
        {
          products(first: 1, query: "sku:#{sku}") {
            edges {
              node {
                id
                variants(first: 10) {
                  edges {
                    node {
                      sku
                      product {
                        id
                      }
                    }
                  }
                }
              }
            }
          }
        }
      GRAPHQL
    
      client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
      response = client.query(query: query)
    
      variant = response.body.dig("data", "products", "edges", 0, "node", "variants", "edges")&.find do |v|
        v.dig("node", "sku") == sku
      end
    
      gid = variant&.dig("node", "product", "id")
      gid&.split("/")&.last # retorna só o número, ex: "7796738523210"
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

    def update_order_processed_at_graphql(order_id, new_date)
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
      )

      # Formata a data para ISO8601
      processed_at = if new_date.is_a?(String)
                      DateTime.strptime(new_date, "%d/%m/%Y").iso8601
                    else
                      new_date.iso8601
                    end

      mutation = <<~GRAPHQL
        mutation {
          orderUpdate(input: {
            id: "gid://shopify/Order/#{order_id}",
            metafields: [
              {
                key: "created_at",
                namespace: "custom",
                value: "#{processed_at}",
                type: "date_time"
              }
            ]
          }) {
            order {
              id
              metafields(namespace: "custom", first: 10) {
                edges {
                  node {
                    key
                    value
                  }
                }
              }
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      begin
        client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
        response = client.query(query: mutation)

        if response.body["errors"].present?
          puts "Erro na mutação GraphQL: #{response.body["errors"]}"
          false
        else
          puts "Data processada armazenada em metafield: #{processed_at}"
          true
        end
      rescue => e
        puts "Erro GraphQL: #{e.message}"
        false
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
