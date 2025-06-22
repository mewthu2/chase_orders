class DiscountsController < ApplicationController
  before_action :authenticate_user!
  before_action :setup_shopify_session
  before_action :admin_or_manager!, except: []
  before_action :admin_only!, only: [:logs]

  def index
  end

  def search
    @coupon_code = params[:coupon_code]&.strip
    
    if @coupon_code.blank?
      flash[:error] = "Por favor, digite um código de cupom."
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
        flash[:success] = "Cupom encontrado!"
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
    price_rule_id = params[:price_rule_id]
    action = params[:action_type]
    coupon_code = params[:coupon_code]
    
    begin
      current_discount = find_discount_by_code(coupon_code)
      old_status = current_discount ? (current_discount[:is_active] ? 'active' : 'inactive') : 'unknown'
      old_ends_at = current_discount&.dig(:price_rule, 'ends_at')
      
      case action
      when 'deactivate'
        new_ends_at = Time.current.iso8601
        @client.put(
          path: "price_rules/#{price_rule_id}.json",
          body: {
            price_rule: {
              ends_at: new_ends_at
            }
          }
        )
        
      when 'activate'
        new_ends_at = nil
        @client.put(
          path: "price_rules/#{price_rule_id}.json",
          body: {
            price_rule: {
              ends_at: nil
            }
          }
        )
      end
      
      LogService.log_discount_action(
        user: current_user,
        action: action,
        coupon_code: coupon_code,
        price_rule_id: price_rule_id,
        old_values: {
          status: old_status,
          ends_at: old_ends_at
        },
        new_values: {
          status: action == 'activate' ? 'active' : 'inactive',
          ends_at: new_ends_at
        },
        details: {
          timestamp: Time.current.iso8601
        },
        request: request
      )
      
      flash[:success] = "Status do cupom alterado com sucesso!"
      
    rescue ShopifyAPI::Errors::HttpResponseError => e
      flash[:error] = "Erro ao alterar status do cupom: #{e.message}"
      
      LogService.log_discount_action(
        user: current_user,
        action: action,
        coupon_code: coupon_code,
        price_rule_id: price_rule_id,
        details: {
          attempted_action: action,
          timestamp: Time.current.iso8601
        },
        request: request,
        error: e
      )
    end

    @coupon_code = coupon_code
    @discount_found = find_discount_by_code(@coupon_code) if @coupon_code.present?
    
    render :index
  end

  def update_dates
    price_rule_id = params[:price_rule_id]
    starts_at = params[:starts_at]
    ends_at = params[:ends_at]
    coupon_code = params[:coupon_code]
    
    begin
      current_discount = find_discount_by_code(coupon_code)
      old_starts_at = current_discount&.dig(:price_rule, 'starts_at')
      old_ends_at = current_discount&.dig(:price_rule, 'ends_at')
      
      update_data = {}
      new_starts_at = nil
      new_ends_at = nil
      
      if starts_at.present?
        new_starts_at = Time.parse(starts_at).iso8601
        update_data[:starts_at] = new_starts_at
      end
      
      if ends_at.present?
        new_ends_at = Time.parse(ends_at).iso8601
        update_data[:ends_at] = new_ends_at
      else
        update_data[:ends_at] = nil
      end
      
      @client.put(
        path: "price_rules/#{price_rule_id}.json",
        body: {
          price_rule: update_data
        }
      )
      
      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: price_rule_id,
        old_values: {
          starts_at: old_starts_at,
          ends_at: old_ends_at
        },
        new_values: {
          starts_at: new_starts_at,
          ends_at: new_ends_at
        },
        details: {
          timestamp: Time.current.iso8601
        },
        request: request
      )
      
      flash[:success] = "Datas do cupom atualizadas com sucesso!"
      
    rescue ShopifyAPI::Errors::HttpResponseError => e
      flash[:error] = "Erro ao atualizar datas: #{e.message}"
      
      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: price_rule_id,
        details: {
          attempted_starts_at: starts_at,
          attempted_ends_at: ends_at,
          timestamp: Time.current.iso8601
        },
        request: request,
        error: e
      )
    rescue ArgumentError => e
      flash[:error] = "Formato de data inválido. Use o formato DD/MM/AAAA HH:MM"
      
      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: price_rule_id,
        details: {
          attempted_starts_at: starts_at,
          attempted_ends_at: ends_at,
          timestamp: Time.current.iso8601
        },
        request: request,
        error: e
      )
    end

    @coupon_code = coupon_code
    @discount_found = find_discount_by_code(@coupon_code) if @coupon_code.present?
    
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
    access_token = ENV.fetch('LAGOA_SECA_TOKEN_APP')
    
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: access_token
    )

    @client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def find_discount_by_code(code)
    limit = 50
    page_info = nil
    
    5.times do
      query_params = { limit: limit }
      query_params[:page_info] = page_info if page_info.present?
      
      response = @client.get(path: "price_rules.json", query: query_params)
      price_rules = response.body['price_rules'] || []
      
      break if price_rules.empty?
      
      price_rules.each do |price_rule|
        discount_codes_response = @client.get(path: "price_rules/#{price_rule['id']}/discount_codes.json")
        discount_codes = discount_codes_response.body['discount_codes'] || []
        
        matching_code = discount_codes.find { |dc| dc['code'].downcase == code.downcase }
        
        if matching_code
          return {
            discount_code: matching_code,
            price_rule: price_rule,
            is_active: price_rule['ends_at'].nil? || Time.parse(price_rule['ends_at']) > Time.current,
            is_expired: price_rule['ends_at'].present? && Time.parse(price_rule['ends_at']) <= Time.current
          }
        end
      end
      
      link_header = response.headers['Link']
      if link_header&.include?('rel="next"')
        next_link = link_header.split(',').find { |link| link.include?('rel="next"') }
        if next_link
          page_info = next_link.match(/page_info=([^&>]+)/)[1] rescue nil
        end
      else
        break
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