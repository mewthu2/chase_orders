class DiscountsController < ApplicationController
  before_action :authenticate_user!
  before_action :setup_shopify_session, only: [:toggle_status]
  before_action :admin_or_manager!, except: []
  before_action :admin_only!, only: [:logs, :sync]

  def index
    @recent_searches = get_recent_searches
  end

  def search
    @coupon_code = params[:coupon_code]&.strip

    if @coupon_code.blank?
      flash[:error] = 'Por favor, digite um código de cupom.'
      render :index and return
    end

    begin
      # Busca no banco local primeiro
      @discount_found = find_discount_in_database(@coupon_code)

      LogService.log_discount_action(
        user: current_user,
        action: 'search',
        coupon_code: @coupon_code,
        details: {
          found: @discount_found.present?,
          search_term: @coupon_code,
          timestamp: Time.current.iso8601,
          source: 'database'
        },
        request: request
      )

      if @discount_found
        flash[:success] = 'Cupom encontrado!'
      else
        flash[:error] = "Cupom '#{@coupon_code}' não encontrado."
      end

    rescue StandardError => e
      flash[:error] = "Erro ao buscar cupom: #{e.message}"
      @discount_found = nil

      LogService.log_discount_action(
        user: current_user,
        action: 'search',
        coupon_code: @coupon_code,
        details: {
          search_term: @coupon_code,
          timestamp: Time.current.iso8601,
          error: e.message
        },
        request: request,
        error: e
      )
    end

    @recent_searches = get_recent_searches
    render :index
  end

  def toggle_status
    discount_id = params[:discount_id]
    action = params[:action_type]
    coupon_code = params[:coupon_code]

    begin
      # Busca o cupom no banco local
      discount = Discount.find(discount_id)
      
      old_status = discount.is_active ? 'active' : 'inactive'
      old_ends_at = discount.ends_at

      # Atualiza no Shopify primeiro
      shopify_result = update_discount_in_shopify(discount, action)
      
      if shopify_result[:success]
        # Se deu certo no Shopify, atualiza no banco local
        case action
        when 'deactivate'
          discount.update!(
            is_active: false,
            is_expired: true,
            ends_at: Time.current,
            last_synced_at: Time.current
          )
        when 'activate'
          discount.update!(
            is_active: true,
            is_expired: false,
            ends_at: nil,
            last_synced_at: Time.current
          )
        end

        # Atualiza os dados para exibição
        @discount_found = format_discount_for_display(discount)
        
        LogService.log_discount_action(
          user: current_user,
          action: action,
          coupon_code: coupon_code,
          price_rule_id: discount.shopify_price_rule_id,
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
            discount_node_id: discount.shopify_node_id
          },
          request: request
        )
        
        flash[:success] = "Status do cupom alterado com sucesso!"
      else
        raise StandardError, shopify_result[:error]
      end
      
    rescue StandardError => e
      flash[:error] = "Erro ao alterar status do cupom: #{e.message}"
      @discount_found = format_discount_for_display(discount) if discount
      
      LogService.log_discount_action(
        user: current_user,
        action: action,
        coupon_code: coupon_code,
        price_rule_id: discount&.shopify_price_rule_id,
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
    @recent_searches = get_recent_searches
    render :index
  end

  def sync
    SyncShopifyDiscountsJob.perform_later(force_full_sync: params[:force] == 'true')
    flash[:success] = 'Sincronização de cupons iniciada em background!'
    redirect_to discounts_path
  end

  def logs
    @logs = Log.includes(:user)
               .where(user_id: current_user.id)
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

  def get_recent_searches
    Log.includes(:user)
       .by_resource_type('discount')
       .by_action_type('search')
       .where(user: current_user)
       .where('created_at >= ?', 7.days.ago)
       .order(created_at: :desc)
       .limit(10)
       .map do |log|
         details = log.details
         found = false
         
         if details.is_a?(String)
           begin
             parsed_details = JSON.parse(details)
             found = parsed_details['found'] || false
           rescue JSON::ParserError
             found = false
           end
         elsif details.is_a?(Hash)
           found = details['found'] || false
         end
         
         {
           coupon_code: log.resource_name,
           user: log.user&.email || 'Sistema',
           searched_at: log.created_at,
           found: found
         }
       end
       .uniq { |search| search[:coupon_code] }
       .first(5)
  end

  def setup_shopify_session
    access_token = ENV.fetch('CHASE_ORDERS_TOKEN')

    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
    )

    @client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def find_discount_in_database(code)
    discount = Discount.find_by_code(code)
    return nil unless discount

    # Atualiza o status baseado nas datas se necessário
    discount.update_status_from_dates! if discount.ends_at.present?

    format_discount_for_display(discount)
  end

  def format_discount_for_display(discount)
    {
      node_id: discount.shopify_node_id,
      discount_code: {
        'code' => discount.code
      },
      discount_data: discount.shopify_data || {},
      is_active: discount.is_active,
      is_expired: discount.is_expired,
      detailed_info: {
        discount_type: discount.discount_type,
        discount_value: discount.discount_value,
        currency_code: discount.currency_code,
        applies_to: discount.applies_to,
        min_purchase_amount: discount.min_purchase_amount,
        min_quantity: discount.min_quantity,
        customer_eligibility: discount.customer_eligibility,
        usage_limit: discount.usage_limit,
        one_per_customer: discount.one_per_customer,
        combines_with_product: discount.combines_with_product,
        combines_with_shipping: discount.combines_with_shipping,
        combines_with_order: discount.combines_with_order,
        status: discount.status,
        usage_count: discount.usage_count
      },
      price_rule: {
        'id' => discount.shopify_price_rule_id,
        'title' => discount.title,
        'value_type' => discount.discount_type,
        'value' => discount.discount_value,
        'usage_limit' => discount.usage_limit,
        'starts_at' => discount.starts_at&.iso8601,
        'ends_at' => discount.ends_at&.iso8601,
        'created_at' => discount.shopify_created_at&.iso8601,
        'updated_at' => discount.shopify_updated_at&.iso8601
      },
      database_id: discount.id
    }
  end

  def update_discount_in_shopify(discount, action)
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
        id: discount.shopify_node_id,
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
        id: discount.shopify_node_id,
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
        return { success: false, error: "Erros da API Shopify: #{error_messages}" }
      end

      return { success: true }
    elsif response.body['errors']
      error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
      return { success: false, error: "Erros GraphQL: #{error_messages}" }
    end

    { success: false, error: "Resposta inesperada da API Shopify" }
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
