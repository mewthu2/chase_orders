class SyncShopifyDiscountsJob < ApplicationJob
  queue_as :default

  def perform(force_full_sync: false)
    Rails.logger.info 'Iniciando sincronização de cupons Shopify...'

    setup_shopify_session

    synced_count = 0
    created_count = 0
    updated_count = 0
    errors_count = 0

    begin
      after_cursor = nil

      loop do
        query = build_sync_query(after_cursor)

        response = @client.post(path: 'graphql.json', body: { query: })

        unless response.body.is_a?(Hash)
          raise StandardError, 'Resposta inválida da API Shopify'
        end

        if response.body['errors']
          error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
          raise StandardError, "Erros GraphQL: #{error_messages}"
        end

        data = response.body.dig('data', 'codeDiscountNodes')

        unless data
          raise StandardError, 'Dados de cupons não encontrados na resposta da API'
        end

        edges = data['edges'] || []
        page_info = data['pageInfo']
        
        edges.each do |edge|
          begin
            result = process_discount_edge(edge, force_full_sync)
            
            case result[:action]
            when :created
              created_count += 1
            when :updated
              updated_count += 1
            end
            
            synced_count += 1
            
          rescue StandardError => e
            Rails.logger.error "Erro ao processar cupom #{edge.dig('node', 'id')}: #{e.message}"
            errors_count += 1
          end
        end
        
        break unless page_info['hasNextPage']
        after_cursor = page_info['endCursor']
      end
      
      # Marcar cupons que não foram encontrados como precisando de sincronização
      if force_full_sync
        Discount.where('last_synced_at < ?', 1.hour.ago).update_all(needs_sync: true)
      end
      
      Rails.logger.info "Sincronização concluída: #{synced_count} processados, #{created_count} criados, #{updated_count} atualizados, #{errors_count} erros"
      
    rescue StandardError => e
      Rails.logger.error "Erro na sincronização de cupons: #{e.message}"
      raise e
    end
  end

  private

  def setup_shopify_session
    access_token = ENV.fetch('CHASE_ORDERS_TOKEN')

    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
    )

    @client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def build_sync_query(after_cursor)
    <<~GRAPHQL
      {
        codeDiscountNodes(first: 250#{after_cursor ? ", after: \"#{after_cursor}\"" : ''}) {
          pageInfo {
            hasNextPage
            endCursor
          }
          edges {
            node {
              id
              codeDiscount {
                __typename
                ... on DiscountCodeBasic {
                  codes(first: 10) {
                    nodes {
                      code
                    }
                  }
                  startsAt
                  endsAt
                  title
                  summary
                  usageLimit
                  appliesOncePerCustomer
                  combinesWith {
                    orderDiscounts
                    productDiscounts
                    shippingDiscounts
                  }
                  customerGets {
                    value {
                      ... on DiscountPercentage {
                        percentage
                      }
                      ... on DiscountAmount {
                        amount {
                          amount
                          currencyCode
                        }
                      }
                    }
                    items {
                      ... on AllDiscountItems {
                        allItems
                      }
                    }
                  }
                  minimumRequirement {
                    ... on DiscountMinimumQuantity {
                      greaterThanOrEqualToQuantity
                    }
                    ... on DiscountMinimumSubtotal {
                      greaterThanOrEqualToSubtotal {
                        amount
                        currencyCode
                      }
                    }
                  }
                  customerSelection {
                    ... on DiscountCustomerAll {
                      allCustomers
                    }
                  }
                  createdAt
                  updatedAt
                  asyncUsageCount
                  status
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end

  def process_discount_edge(edge, force_update = false)
    return { action: :skipped } unless edge && edge['node'] && edge['node']['codeDiscount']

    discount_data = edge['node']['codeDiscount']
    return { action: :skipped } unless discount_data && discount_data['__typename'] == 'DiscountCodeBasic'

    codes = discount_data.dig('codes', 'nodes') || []
    return { action: :skipped } if codes.empty?

    # Pega o primeiro código (assumindo que cada desconto tem um código principal)
    main_code = codes.first
    return { action: :skipped } unless main_code && main_code['code']

    node_id = edge['node']['id']
    existing_discount = Discount.find_by(shopify_node_id: node_id)

    discount_attributes = extract_discount_attributes(edge, discount_data, main_code)

    if existing_discount
      # Só atualiza se forçado ou se os dados mudaram
      if force_update || should_update_discount?(existing_discount, discount_attributes)
        existing_discount.update!(discount_attributes)
        { action: :updated, discount: existing_discount }
      else
        existing_discount.touch(:last_synced_at)
        { action: :skipped, discount: existing_discount }
      end
    else
      new_discount = Discount.create!(discount_attributes)
      { action: :created, discount: new_discount }
    end
  end

  def extract_discount_attributes(edge, discount_data, main_code)
    ends_at = discount_data['endsAt'] ? Time.parse(discount_data['endsAt']) : nil
    starts_at = discount_data['startsAt'] ? Time.parse(discount_data['startsAt']) : nil
    now = Time.current

    is_active = true
    is_expired = false

    if starts_at && starts_at > now
      is_active = false
    elsif ends_at && ends_at <= now
      is_active = false
      is_expired = true
    end

    customer_gets = discount_data['customerGets']
    discount_value = nil
    discount_type = nil
    currency_code = 'BRL'

    if customer_gets && customer_gets['value']
      if customer_gets['value']['percentage']
        discount_value = customer_gets['value']['percentage']
        discount_type = 'percentage'
      elsif customer_gets['value']['amount']
        discount_value = customer_gets['value']['amount']['amount']
        currency_code = customer_gets['value']['amount']['currencyCode'] || 'BRL'
        discount_type = 'fixed_amount'
      end
    end

    minimum_requirement = discount_data['minimumRequirement']
    min_purchase_amount = nil
    min_quantity = nil

    if minimum_requirement&.is_a?(Hash)
      if minimum_requirement['greaterThanOrEqualToSubtotal']
        subtotal_data = minimum_requirement['greaterThanOrEqualToSubtotal']
        min_purchase_amount = subtotal_data['amount'].to_f if subtotal_data && subtotal_data['amount']
      elsif minimum_requirement['greaterThanOrEqualToQuantity']
        min_quantity = minimum_requirement['greaterThanOrEqualToQuantity']
      end
    end

    combines_with = discount_data['combinesWith'] || {}
    
    customer_selection = discount_data['customerSelection']
    customer_eligibility = if customer_selection && customer_selection['allCustomers']
                            'Todos os clientes'
                          else
                            'Clientes específicos'
                          end

    {
      shopify_node_id: edge['node']['id'],
      shopify_price_rule_id: edge['node']['id'].split('/').last,
      code: main_code['code'],
      title: discount_data['title'] || main_code['code'],
      summary: discount_data['summary'],
      is_active: is_active,
      is_expired: is_expired,
      status: discount_data['status'] || 'ACTIVE',
      starts_at: starts_at,
      ends_at: ends_at,
      shopify_created_at: discount_data['createdAt'] ? Time.parse(discount_data['createdAt']) : nil,
      shopify_updated_at: discount_data['updatedAt'] ? Time.parse(discount_data['updatedAt']) : nil,
      discount_type: discount_type || 'percentage',
      discount_value: discount_value || 0,
      currency_code: currency_code,
      applies_to: (customer_gets&.dig('items', 'allItems') ? 'Pedido inteiro' : 'Produtos específicos'),
      min_purchase_amount: min_purchase_amount,
      min_quantity: min_quantity,
      customer_eligibility: customer_eligibility,
      usage_limit: discount_data['usageLimit'],
      usage_count: discount_data['asyncUsageCount'] || 0,
      one_per_customer: discount_data['appliesOncePerCustomer'] || false,
      combines_with_product: combines_with['productDiscounts'] || false,
      combines_with_shipping: combines_with['shippingDiscounts'] || false,
      combines_with_order: combines_with['orderDiscounts'] || false,
      shopify_data: discount_data,
      last_synced_at: Time.current,
      needs_sync: false
    }
  end

  def should_update_discount?(existing_discount, new_attributes)
    important_fields = [
      :title, :is_active, :is_expired, :starts_at, :ends_at,
      :discount_value, :usage_count, :usage_limit
    ]

    important_fields.any? do |field|
      existing_discount.send(field) != new_attributes[field]
    end
  end
end
