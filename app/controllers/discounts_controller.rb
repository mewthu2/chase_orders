class DiscountsController < ApplicationController
  before_action :authenticate_user!
  before_action :setup_shopify_session
  before_action :admin_or_manager!, except: []
  before_action :admin_only!, only: [:logs]

  def index; end

  def search
    @coupon_code = params[:coupon_code]&.strip

    if @coupon_code.blank?
      flash[:error] = 'Por favor, digite um código de cupom.'
      render :index and return
    end

    begin
      @discount_found = find_discount_by_code(@coupon_code)

      LogService.log_discount_action(
        user: current_user,
        action: 'search',
        coupon_code: @coupon_code,
        details: {
          found: @discount_found.present?,
          search_term: @coupon_code,
          timestamp: Time.current.iso8601
        },
        request: request
      )

      if @discount_found
        flash[:success] = 'Cupom encontrado!'
      else
        flash[:error] = "Cupom '#{@coupon_code}' não encontrado."
      end

    rescue ShopifyAPI::Errors::HttpResponseError => e
      flash[:error] = "Erro ao buscar cupom: #{e.message}"
      @discount_found = nil

      LogService.log_discount_action(
        user: current_user,
        action: 'search',
        coupon_code: @coupon_code,
        details: {
          search_term: @coupon_code,
          timestamp: Time.current.iso8601
        },
        request: request,
        error: e
      )
    end

    render :index
  end

  def toggle_status
    discount_node_id = params[:discount_node_id]
    action = params[:action_type]
    coupon_code = params[:coupon_code]

    begin
      current_discount = find_discount_by_code(coupon_code)
      old_status = current_discount ? (current_discount[:is_active] ? 'active' : 'inactive') : 'unknown'
      old_ends_at = current_discount&.dig(:discount_data, 'endsAt')

      case action
      when 'deactivate'
        new_ends_at = Time.current.iso8601
        
        mutation = <<~GRAPHQL
          mutation discountCodeBasicUpdate($id: ID!, $basicCodeDiscount: DiscountCodeBasicInput!) {
            discountCodeBasicUpdate(id: $id, basicCodeDiscount: $basicCodeDiscount) {
              codeDiscountNode {
                id
                codeDiscount {
                  ... on DiscountCodeBasic {
                    endsAt
                    startsAt
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

        variables = {
          id: discount_node_id,
          basicCodeDiscount: {
            endsAt: new_ends_at
          }
        }

      when 'activate'
        mutation = <<~GRAPHQL
          mutation discountCodeBasicUpdate($id: ID!, $basicCodeDiscount: DiscountCodeBasicInput!) {
            discountCodeBasicUpdate(id: $id, basicCodeDiscount: $basicCodeDiscount) {
              codeDiscountNode {
                id
                codeDiscount {
                  ... on DiscountCodeBasic {
                    endsAt
                    startsAt
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

        variables = {
          id: discount_node_id,
          basicCodeDiscount: {
            endsAt: nil
          }
        }
      end

      response = @client.post(
        path: 'graphql.json',
        body: {
          query: mutation,
          variables: variables
        }
      )

      if response.body['data'] && response.body['data']['discountCodeBasicUpdate']
        user_errors = response.body['data']['discountCodeBasicUpdate']['userErrors']
        
        if user_errors && user_errors.any?
          error_messages = user_errors.map { |error| "#{error['field']}: #{error['message']}" }.join(', ')
          raise StandardError, "Erros da API Shopify: #{error_messages}"
        end

        updated_discount_data = response.body.dig('data', 'discountCodeBasicUpdate', 'codeDiscountNode', 'codeDiscount')
        
        if updated_discount_data && current_discount
          new_ends_at_from_api = updated_discount_data['endsAt']
          starts_at_from_api = updated_discount_data['startsAt']
          now = Time.current

          is_active = true
          is_expired = false

          if starts_at_from_api && Time.parse(starts_at_from_api) > now
            is_active = false
          elsif new_ends_at_from_api && Time.parse(new_ends_at_from_api) <= now
            is_active = false
            is_expired = true
          end

          current_discount[:is_active] = is_active
          current_discount[:is_expired] = is_expired
          current_discount[:discount_data]['endsAt'] = new_ends_at_from_api
          current_discount[:price_rule]['ends_at'] = new_ends_at_from_api

          @discount_found = current_discount
        end

      elsif response.body['errors']
        error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
        raise StandardError, "Erros GraphQL: #{error_messages}"
      end
      
      numeric_id = discount_node_id.split('/').last

      LogService.log_discount_action(
        user: current_user,
        action: action,
        coupon_code: coupon_code,
        price_rule_id: numeric_id,
        old_values: {
          status: old_status,
          ends_at: old_ends_at
        },
        new_values: {
          status: action == 'activate' ? 'active' : 'inactive',
          ends_at: action == 'deactivate' ? Time.current.iso8601 : nil
        },
        details: {
          timestamp: Time.current.iso8601,
          discount_node_id: discount_node_id
        },
        request: request
      )
      
      flash[:success] = "Status do cupom alterado com sucesso!"
      
    rescue StandardError => e
      flash[:error] = "Erro ao alterar status do cupom: #{e.message}"
      @discount_found = current_discount
      
      LogService.log_discount_action(
        user: current_user,
        action: action,
        coupon_code: coupon_code,
        price_rule_id: discount_node_id,
        details: {
          attempted_action: action,
          timestamp: Time.current.iso8601,
          error_message: e.message
        },
        request: request,
        error: e
      )
    end

    @coupon_code = coupon_code
    render :index
  end

  def logs
    @logs = Log.includes(:user)
               .by_resource_type('discount')
               .recent
               .page(params[:page])
               .per(50)
    
    if params[:action_filter].present?
      @logs = @logs.by_action_type(params[:action_filter])
    end
    
    if params[:user_filter].present?
      @logs = @logs.by_user(params[:user_filter])
    end
    
    if params[:coupon_filter].present?
      @logs = @logs.where("resource_name ILIKE ?", "%#{params[:coupon_filter]}%")
    end

    if params[:status_filter].present?
      case params[:status_filter]
      when 'success'
        @logs = @logs.successful
      when 'error'
        @logs = @logs.failed
      end
    end
    
    @users = User.all.order(:email)
    @actions = Log.by_resource_type('discount').distinct.pluck(:action_type)
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

  def find_discount_by_code(code)
    after_cursor = nil
    code = code.strip.downcase

    loop do
      query = <<~GRAPHQL
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
      
      begin
        response = @client.post(path: 'graphql.json', body: { query: query })
        
        unless response.body.is_a?(Hash)
          raise StandardError, "Resposta inválida da API Shopify"
        end

        if response.body['errors']
          error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
          raise StandardError, "Erros GraphQL: #{error_messages}"
        end

        data = response.body.dig('data', 'codeDiscountNodes')
        
        unless data
          raise StandardError, "Dados de cupons não encontrados na resposta da API"
        end

        edges = data['edges'] || []
        page_info = data['pageInfo']
        
        unless page_info
          raise StandardError, "Informações de paginação não encontradas"
        end
        
        after_cursor = page_info['endCursor']

        edges.each do |edge|
          unless edge && edge['node'] && edge['node']['codeDiscount']
            next
          end

          discount = edge['node']['codeDiscount']
          next unless discount && discount['__typename'] == 'DiscountCodeBasic'

          codes = discount.dig('codes', 'nodes') || []

          codes.each do |dc|
            unless dc && dc['code']
              next
            end

            if dc['code'].downcase == code
              ends_at = discount['endsAt']
              starts_at = discount['startsAt']
              now = Time.current

              is_active = true
              is_expired = false

              if starts_at && Time.parse(starts_at) > now
                is_active = false
              elsif ends_at && Time.parse(ends_at) <= now
                is_active = false
                is_expired = true
              end

              customer_gets = discount['customerGets']
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

              minimum_requirement = discount['minimumRequirement']
              min_purchase_amount = nil
              min_quantity = nil

              if minimum_requirement
                if minimum_requirement.is_a?(Hash)
                  if minimum_requirement['greaterThanOrEqualToSubtotal']
                    subtotal_data = minimum_requirement['greaterThanOrEqualToSubtotal']
                    
                    if subtotal_data && subtotal_data['amount']
                      min_purchase_amount = subtotal_data['amount'].to_f
                    end
                  elsif minimum_requirement['greaterThanOrEqualToQuantity']
                    min_quantity = minimum_requirement['greaterThanOrEqualToQuantity']
                  end
                end
              end

              combines_with = discount['combinesWith'] || {}
              
              customer_selection = discount['customerSelection']
              customer_eligibility = 'Todos os clientes'
              
              if customer_selection
                if customer_selection['allCustomers']
                  customer_eligibility = 'Todos os clientes'
                else
                  customer_eligibility = 'Clientes específicos'
                end
              end

              return {
                node_id: edge['node']['id'],
                discount_code: {
                  'code' => dc['code']
                },
                discount_data: discount,
                is_active: is_active,
                is_expired: is_expired,
                detailed_info: {
                  discount_type: discount_type || 'percentage',
                  discount_value: discount_value || 0,
                  currency_code: currency_code,
                  applies_to: (customer_gets&.dig('items', 'allItems') ? 'Pedido inteiro' : 'Produtos específicos'),
                  min_purchase_amount: min_purchase_amount,
                  min_quantity: min_quantity,
                  customer_eligibility: customer_eligibility,
                  usage_limit: discount['usageLimit'],
                  one_per_customer: discount['appliesOncePerCustomer'] || false,
                  combines_with_product: combines_with['productDiscounts'] || false,
                  combines_with_shipping: combines_with['shippingDiscounts'] || false,
                  combines_with_order: combines_with['orderDiscounts'] || false,
                  status: discount['status'] || 'ACTIVE',
                  usage_count: discount['asyncUsageCount'] || 0
                },
                price_rule: {
                  'id' => edge['node']['id'].split('/').last,
                  'title' => discount['title'] || dc['code'],
                  'value_type' => discount_type || 'percentage',
                  'value' => discount_value || 0,
                  'usage_limit' => discount['usageLimit'],
                  'starts_at' => starts_at,
                  'ends_at' => ends_at,
                  'created_at' => discount['createdAt'],
                  'updated_at' => discount['updatedAt']
                }
              }
            end
          end
        end

        break unless page_info['hasNextPage']
        
      rescue StandardError => e
        raise e
      end
    end

    nil
  end

  def admin_or_manager!
    unless current_user&.admin? || current_user&.manager?
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end

  def admin_only!
    unless current_user&.admin?
      redirect_to root_path, alert: 'Acesso negado.'
    end
  end
end