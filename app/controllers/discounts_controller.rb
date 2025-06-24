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

    puts "🔧 Toggle Status - Node ID: #{discount_node_id}, Action: #{action}, Code: #{coupon_code}"

    begin
      current_discount = find_discount_by_code(coupon_code)
      old_status = current_discount ? (current_discount[:is_active] ? 'active' : 'inactive') : 'unknown'
      old_ends_at = current_discount&.dig(:discount_data, 'endsAt')

      case action
      when 'deactivate'
        new_ends_at = Time.current.iso8601
        puts "🔧 Desativando cupom - definindo endsAt para: #{new_ends_at}"
        
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
        puts "🔧 Ativando cupom - removendo endsAt"
        
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

      puts "🔧 Enviando mutation GraphQL..."
      puts "Variables: #{variables.inspect}"

      response = @client.post(
        path: 'graphql.json',
        body: {
          query: mutation,
          variables: variables
        }
      )

      puts "🔧 Resposta da API: #{response.body.inspect}"

      # Verificar se houve erros na resposta
      if response.body['data'] && response.body['data']['discountCodeBasicUpdate']
        user_errors = response.body['data']['discountCodeBasicUpdate']['userErrors']
        
        if user_errors && user_errors.any?
          error_messages = user_errors.map { |error| "#{error['field']}: #{error['message']}" }.join(', ')
          raise StandardError, "Erros da API Shopify: #{error_messages}"
        end

        # ✅ OTIMIZAÇÃO: Atualizar dados localmente em vez de fazer nova busca
        updated_discount_data = response.body.dig('data', 'discountCodeBasicUpdate', 'codeDiscountNode', 'codeDiscount')
        
        if updated_discount_data && current_discount
          # Atualizar os dados locais com a resposta da API
          new_ends_at_from_api = updated_discount_data['endsAt']
          starts_at_from_api = updated_discount_data['startsAt']
          now = Time.current

          # Recalcular status baseado nos novos dados
          is_active = true
          is_expired = false

          if starts_at_from_api && Time.parse(starts_at_from_api) > now
            is_active = false # Ainda não começou
          elsif new_ends_at_from_api && Time.parse(new_ends_at_from_api) <= now
            is_active = false
            is_expired = true
          end

          # Atualizar o hash existente
          current_discount[:is_active] = is_active
          current_discount[:is_expired] = is_expired
          current_discount[:discount_data]['endsAt'] = new_ends_at_from_api
          current_discount[:price_rule]['ends_at'] = new_ends_at_from_api

          @discount_found = current_discount
          puts "✅ Dados atualizados localmente - Status: #{is_active ? 'Ativo' : 'Inativo'}"
        end

      elsif response.body['errors']
        error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
        raise StandardError, "Erros GraphQL: #{error_messages}"
      end
      
      # Extrair o ID numérico do GID do Shopify para logs
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
      puts "❌ Erro ao alterar status: #{e.message}"
      flash[:error] = "Erro ao alterar status do cupom: #{e.message}"
      
      # Em caso de erro, manter os dados atuais
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

  def update_dates
    discount_node_id = params[:discount_node_id]
    starts_at = params[:starts_at]
    ends_at = params[:ends_at]
    coupon_code = params[:coupon_code]

    puts "🔧 Update Dates - Node ID: #{discount_node_id}, Starts: #{starts_at}, Ends: #{ends_at}"

    begin
      current_discount = find_discount_by_code(coupon_code)
      old_starts_at = current_discount&.dig(:discount_data, 'startsAt')
      old_ends_at = current_discount&.dig(:discount_data, 'endsAt')

      new_starts_at = nil
      new_ends_at = nil

      if starts_at.present?
        new_starts_at = Time.parse(starts_at).iso8601
      end

      if ends_at.present?
        new_ends_at = Time.parse(ends_at).iso8601
      end

      mutation = <<~GRAPHQL
        mutation discountCodeBasicUpdate($id: ID!, $basicCodeDiscount: DiscountCodeBasicInput!) {
          discountCodeBasicUpdate(id: $id, basicCodeDiscount: $basicCodeDiscount) {
            codeDiscountNode {
              id
              codeDiscount {
                ... on DiscountCodeBasic {
                  startsAt
                  endsAt
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
        basicCodeDiscount: {}
      }

      variables[:basicCodeDiscount][:startsAt] = new_starts_at if new_starts_at
      variables[:basicCodeDiscount][:endsAt] = new_ends_at

      puts "🔧 Enviando mutation para atualizar datas..."
      puts "Variables: #{variables.inspect}"

      response = @client.post(
        path: 'graphql.json',
        body: {
          query: mutation,
          variables: variables
        }
      )

      puts "🔧 Resposta da API: #{response.body.inspect}"

      # Verificar se houve erros na resposta
      if response.body['data'] && response.body['data']['discountCodeBasicUpdate']
        user_errors = response.body['data']['discountCodeBasicUpdate']['userErrors']
        
        if user_errors && user_errors.any?
          error_messages = user_errors.map { |error| "#{error['field']}: #{error['message']}" }.join(', ')
          raise StandardError, "Erros da API Shopify: #{error_messages}"
        end

        # ✅ OTIMIZAÇÃO: Atualizar dados localmente
        updated_discount_data = response.body.dig('data', 'discountCodeBasicUpdate', 'codeDiscountNode', 'codeDiscount')
        
        if updated_discount_data && current_discount
          updated_starts_at = updated_discount_data['startsAt']
          updated_ends_at = updated_discount_data['endsAt']
          now = Time.current

          # Recalcular status baseado nas novas datas
          is_active = true
          is_expired = false

          if updated_starts_at && Time.parse(updated_starts_at) > now
            is_active = false # Ainda não começou
          elsif updated_ends_at && Time.parse(updated_ends_at) <= now
            is_active = false
            is_expired = true
          end

          # Atualizar o hash existente
          current_discount[:is_active] = is_active
          current_discount[:is_expired] = is_expired
          current_discount[:discount_data]['startsAt'] = updated_starts_at
          current_discount[:discount_data]['endsAt'] = updated_ends_at
          current_discount[:price_rule]['starts_at'] = updated_starts_at
          current_discount[:price_rule]['ends_at'] = updated_ends_at

          @discount_found = current_discount
          puts "✅ Datas atualizadas localmente"
        end

      elsif response.body['errors']
        error_messages = response.body['errors'].map { |error| error['message'] }.join(', ')
        raise StandardError, "Erros GraphQL: #{error_messages}"
      end

      # Extrair o ID numérico do GID do Shopify para logs
      numeric_id = discount_node_id.split('/').last

      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: numeric_id,
        old_values: {
          starts_at: old_starts_at,
          ends_at: old_ends_at
        },
        new_values: {
          starts_at: new_starts_at,
          ends_at: new_ends_at
        },
        details: {
          timestamp: Time.current.iso8601,
          discount_node_id: discount_node_id
        },
        request: request
      )

      flash[:success] = 'Datas do cupom atualizadas com sucesso!'

    rescue StandardError => e
      puts "❌ Erro ao atualizar datas: #{e.message}"
      flash[:error] = "Erro ao atualizar datas: #{e.message}"

      # Em caso de erro, manter os dados atuais
      @discount_found = current_discount

      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: discount_node_id,
        details: {
          attempted_starts_at: starts_at,
          attempted_ends_at: ends_at,
          timestamp: Time.current.iso8601,
          error_message: e.message
        },
        request: request,
        error: e
      )
    rescue ArgumentError => e
      flash[:error] = "Formato de data inválido. Use o formato DD/MM/AAAA HH:MM"
      
      # Em caso de erro, manter os dados atuais
      @discount_found = current_discount
      
      LogService.log_discount_action(
        user: current_user,
        action: 'update_dates',
        coupon_code: coupon_code,
        price_rule_id: discount_node_id,
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
                    customerGets {
                      value {
                        ... on DiscountPercentage {
                          percentage
                        }
                        ... on DiscountAmount {
                          amount {
                            amount
                          }
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
                  }
                }
              }
            }
          }
        }
      GRAPHQL

      response = @client.post(path: 'graphql.json', body: { query: query })
      data = response.body.dig('data', 'codeDiscountNodes')

      edges = data['edges'] || []
      page_info = data['pageInfo']
      after_cursor = page_info['endCursor']

      edges.each do |edge|
        discount = edge['node']['codeDiscount']
        next unless discount && discount['__typename'] == 'DiscountCodeBasic'

        codes = discount.dig('codes', 'nodes') || []

        codes.each do |dc|
          puts "🔍 Verificando código: #{dc['code']}"

          if dc['code'].downcase == code
            puts "✅ Cupom encontrado: #{edge}"
            ends_at = discount['endsAt']
            starts_at = discount['startsAt']
            now = Time.current

            # Determinar se está ativo
            is_active = true
            is_expired = false

            if starts_at && Time.parse(starts_at) > now
              is_active = false # Ainda não começou
            elsif ends_at && Time.parse(ends_at) <= now
              is_active = false
              is_expired = true
            end

            # Extrair informações de valor do desconto
            customer_gets = discount['customerGets']
            discount_value = nil
            discount_type = nil

            if customer_gets && customer_gets['value']
              if customer_gets['value']['percentage']
                # ✅ CORREÇÃO: A API do Shopify retorna porcentagem como decimal (0.1 = 10%)
                # Não multiplicamos por 100 aqui, fazemos isso na view
                discount_value = customer_gets['value']['percentage']
                discount_type = 'percentage'
                puts "🔧 Porcentagem encontrada: #{discount_value} (#{discount_value.to_f * 100}%)"
              elsif customer_gets['value']['amount']
                discount_value = customer_gets['value']['amount']['amount']
                discount_type = 'fixed_amount'
                puts "🔧 Valor fixo encontrado: #{discount_value}"
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
              # Manter compatibilidade com a view existente
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