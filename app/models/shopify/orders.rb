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

      response = client.query(query:)
      variant = response.body.dig('data', 'productVariants', 'edges', 0, 'node')
      variant ? variant['id'] : nil
    rescue StandardError => e
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

      nome_completo = cliente['nome'] || 'Cliente Shopify'
      nomes = nome_completo.strip.split
      first_name = nomes.first
      last_name = nomes[1..].join(' ') if nomes.size > 1

      customer_phone = if cliente['fone'].present?
                        generate_unique_phone(cliente['fone'], session)
                      else
                        generate_unique_phone(nil, session)
                      end

      order.customer = {
        'first_name' => first_name || 'Cliente',
        'last_name' => last_name || '',
        'email' => cliente['email'].present? ? cliente['email'] : "sememail_#{SecureRandom.hex(4)}@dominiofalso.com",
        'phone' => customer_phone,
        'tax_exempt' => false,
        'addresses' => [build_address(cliente, customer_phone)],
        'default_address' => build_address(cliente, customer_phone)
      }

      endereco = build_address(cliente, customer_phone)
      order.shipping_address = endereco
      order.billing_address = endereco

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

      fulfillment_date = format_date(pedido['data_pedido']) || Time.now.iso8601
      if pedido['situacao'] == 'Entregue'
        order.fulfillment_status = 'fulfilled'

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
    rescue StandardError => e
      puts "Erro ao verificar telefone: #{e.message}"
      puts e.backtrace.join("\n")
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

      client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
      response = client.query(query:)

      variant = response.body.dig('data', 'products', 'edges', 0, 'node', 'variants', 'edges')&.find do |v|
        v.dig('node', 'sku') == sku
      end

      gid = variant&.dig('node', 'product', 'id')
      gid&.split('/')&.last
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

    def update_order_processed_at_graphql(order_id, new_date)
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
      )

      processed_at = if new_date.is_a?(String)
                      DateTime.strptime(new_date, '%d/%m/%Y').iso8601
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

        if response.body['errors'].present?
          puts "Erro na mutação GraphQL: #{response.body['errors']}"
          false
        else
          puts "Data processada armazenada em metafield: #{processed_at}"
          true
        end
      rescue StandardError => e
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
      rescue StandardError => e
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

    def sync_shopify_orders_to_rails(limit: 250, status: 'any', time_range: :all, from_date: nil)
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
      )

      client = ShopifyAPI::Clients::Rest::Admin.new(session:)

      total = 0

      created_at_min =
        if from_date.present?
          Time.parse(from_date.to_s).iso8601
        else
          case time_range.to_sym
          when :last_3_days
            3.days.ago.iso8601
          when :last_3_hours
            3.hours.ago.iso8601
          else
            nil
          end
        end

      Rails.logger.info "[Shopify::Orders] Sync iniciado (range: #{time_range}, from_date: #{created_at_min})"

      query_params = {
        limit:,
        status:,
        fields: 'id,created_at,line_items,note_attributes,discount_codes,current_total_price,current_total_discounts'
      }

      query_params[:created_at_min] = created_at_min if created_at_min.present?

      response = client.get(
        path: 'orders',
        query: query_params
      )

      loop do
        response.body['orders'].each do |shopify_order|
          create_or_update_order_from_shopify(shopify_order)
          total += 1

          sleep 1
        end

        break unless response.next_page_info

        sleep 1

        response = client.get(
          path: 'orders',
          query: {
            page_info: response.next_page_info
          }
        )
      end

      Rails.logger.info "[Shopify::Orders] Sincronizados #{total} pedidos"
    end

    def find_or_create_customer_from_shopify(shopify_order)
      customer_stub = shopify_order.customer
      return nil unless customer_stub

      shopify_customer_id = customer_stub.id.to_s

      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
      )

      shopify_customer = ShopifyAPI::Customer.find(
        session:,
        id: shopify_customer_id
      )

      return nil unless shopify_customer

      data = shopify_customer.as_json

      customer = Customer.find_or_initialize_by(
        shopify_customer_id:
      )

      assign_full_customer_data(customer, data)

      customer.save! if customer.changed?

      customer
    end

    def assign_full_customer_data(customer, shopify_customer)
      data = shopify_customer.respond_to?(:as_json) ? shopify_customer.as_json : shopify_customer

      default_address = data['default_address'] || {}
      addresses = data['addresses'] || []

      customer.assign_attributes(
        first_name: data['first_name'],
        last_name: data['last_name'],
        email: data['email'],
        phone: data['phone'],
        currency: data['currency'],
        tags: data['tags'],
        orders_count: data['orders_count'],
        total_spent: data['total_spent'],
        verified_email: data['verified_email'],
        tax_exempt: data['tax_exempt'],
        shopify_created_at: data['created_at'],
        shopify_updated_at: data['updated_at'],
        addresses:
      )

      return unless default_address.present?
      customer.assign_attributes(
        default_address_name: default_address['name'],
        default_address_company: default_address['company'],
        default_address_phone: default_address['phone'],
        default_address_address1: default_address['address1'],
        default_address_address2: default_address['address2'],
        default_address_city: default_address['city'],
        default_address_province: default_address['province'],
        default_address_country: default_address['country'],
        default_address_zip: default_address['zip'],
        default_address_country_code: default_address['country_code'],
        default_address_province_code: default_address['province_code']
      )
    end

    def fetch_shopify_order_by_id(shopify_order_id)
      session = ShopifyAPI::Auth::Session.new(
        shop: 'chasebrasil.myshopify.com',
        access_token: ENV.fetch('BH_SHOPPING_TOKEN_APP')
      )

      shopify_order = ShopifyAPI::Order.find(
        session:,
        id: shopify_order_id
      )

      create_or_update_order_from_shopify(shopify_order) if shopify_order
    rescue ShopifyAPI::Errors::HttpResponseError => e
      puts "Erro ao buscar pedido #{shopify_order_id}: #{e.message}"
      nil
    end

    def create_or_update_order_from_shopify(shopify_order)
      shopify_order_id   = shopify_order.id.to_s
      shopify_created_at = Time.parse(shopify_order.created_at.to_s)

      raw_note_attributes = shopify_order.note_attributes || []

      note_attributes = extract_note_attributes_from_hash(raw_note_attributes)

      staff_id   = note_attributes['staff_ID']
      staff_name = note_attributes['staff_name']

      iglu_payments = parse_iglu_payments(
        note_attributes['iglu_payments']
      )

      current_total_price     = shopify_order.current_total_price&.to_d
      current_total_discounts = shopify_order.current_total_discounts&.to_d

      shopify_discount_codes = Array(shopify_order.discount_codes).map { |d| d.code }

      note_discount_codes = raw_note_attributes.select { |a| a['name'] == 'discount_codes' }.map { |a| a['value'] }

      order_discounts_info = JSON.parse(note_attributes['order_discounts_info'] || '[]')

      extra_discount_codes = order_discounts_info.map { |d| d['description'] }

      discount_codes = (shopify_discount_codes + note_discount_codes + extra_discount_codes).compact.uniq

      location_shopify_id = note_attributes['location_ID']

      location = if location_shopify_id.present?
                   Location.find_by(shopify_location_id: location_shopify_id)
                 else
                   Location.find_by(slug: 'log+')
                 end

      customer = find_or_create_customer_from_shopify(shopify_order)

      order = Order.find_or_initialize_by(
        shopify_order_id:
      )

      order.assign_attributes(
        staff_id: staff_id.presence || order.staff_id,
        staff_name: staff_name.presence || order.staff_name,
        location_id: location&.id,
        shopify_creation_date: shopify_created_at,
        iglu_payments: iglu_payments,
        customer_id: customer&.id,
        note_attributes: raw_note_attributes,
        discount_codes: discount_codes,
        current_total_price: current_total_price,
        current_total_discounts: current_total_discounts
      )

      order.created_at = shopify_created_at if order.new_record?
      order.updated_at = Time.current

      order.save! if order.changed?

      existing_items = order.order_items.index_by(&:sku)

      Array(shopify_order.line_items).each do |line_item|
        sku = line_item.sku
        next if sku.blank?

        price    = line_item.price.to_f
        quantity = line_item.quantity.to_i

        item = existing_items[sku]

        if item
          if item.price != price || item.quantity != quantity
            item.update!(
              price: price,
              quantity: quantity
            )
          end
        else
          product = Product.find_by(sku: sku)

          order.order_items.create!(
            product_id: product&.id,
            sku: sku,
            price: price,
            quantity: quantity,
            canceled: false
          )
        end
      end

      order

    rescue StandardError => e
      Rails.logger.error "[Shopify::Orders] Erro ao processar pedido #{shopify_order_id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      nil
    end

    def extract_note_attributes_from_hash(note_attributes_array)
      return {} unless note_attributes_array.is_a?(Array)

      note_attributes_array.each_with_object({}) do |attr, hash|
        hash[attr['name']] = attr['value']
      end
    end

    def parse_iglu_payments(raw)
      return [] if raw.blank?

      return raw if raw.is_a?(Array)

      JSON.parse(raw)
    rescue JSON::ParserError
      begin
        fixed = raw.gsub(
          /"pix_id"\s*:\s*([A-Za-z0-9]+)/,
          '"pix_id":"\1"'
        )

        JSON.parse(fixed)
      rescue JSON::ParserError
        Rails.logger.warn "[IGLU] JSON inválido ignorado (mantido pedido): #{raw}"
        []
      end
    end

    def update_order_staff_and_payments(shopify_order_id, staff_id:, staff_name:)
      clean_order_id = shopify_order_id.to_s.gsub('gid://shopify/Order/', '')

      order = Order.find_by(shopify_order_id: clean_order_id)
      return nil unless order

      order.update!(
        staff_id: staff_id,
        staff_name: staff_name
      )

      order
    rescue StandardError => e
      puts "Erro ao atualizar pedido: #{e.message}"
      nil
    end
  end
end
