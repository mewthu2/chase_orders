class UpdateShopifyStockFromCorreiosJob < ActiveJob::Base
  MAX_STORED_ERRORS = 50
  MAX_ERROR_LENGTH = 500
  MAX_MESSAGE_LENGTH = 1_000
  MAX_BACKTRACE_LINES = 10

  def perform(attempt_id = nil)
    @attempt = attempt_id ? Attempt.find(attempt_id) : create_new_attempt
    @stats = {
      total: 0,
      success: 0,
      failed: 0,
      errors: [],
      omitted_errors: 0
    }

    begin
      safe_update_attempt!(
        status: :processing,
        message: 'Iniciando sincronização...'
      )

      puts 'Iniciando sincronização de estoque dos Correios para Shopify...'

      products = Product.where.not(sku: [nil, ''])
                        .where.not(shopify_inventory_item_id: [nil, ''])

      total = products.count
      @stats[:total] = total

      puts "Processando #{total} produto(s)..."

      products.find_each.with_index(1) do |product, index|
        update_product_stock(product, index)
      end

      final_message = if @stats[:failed].positive?
                        "Sincronização concluída com erros: #{@stats[:success]}/#{@stats[:total]} produtos atualizados. #{@stats[:failed]} falharam."
                      else
                        "Sincronização concluída! #{@stats[:success]}/#{@stats[:total]} produtos atualizados com sucesso."
                      end

      safe_update_attempt!(
        status: :success,
        message: final_message,
        params: stats_payload.to_json
      )

      puts final_message
    rescue StandardError => e
      error_message = "Erro durante a sincronização: #{e.class}: #{e.message}"
      puts error_message

      record_error(error_message)

      safe_update_attempt!(
        status: :error,
        error: truncate(error_message, MAX_MESSAGE_LENGTH),
        message: truncate(Array(e.backtrace).first(MAX_BACKTRACE_LINES).join("\n"), MAX_MESSAGE_LENGTH),
        params: stats_payload.to_json
      )

      # Não dar raise aqui, senão o Sidekiq vai tentar rodar tudo de novo.
      nil
    end
  end

  private

  def create_new_attempt
    Attempt.create!(
      kinds: :sync_correios_stock,
      status: :processing,
      tracking: "auto_execution:#{Time.current.to_i}",
      message: 'Sincronização automática iniciada'
    )
  end

  def update_product_stock(product, current_index)
    puts "[#{current_index}/#{@stats[:total]}] Processando produto: #{product.sku}"

    begin
      correios_response = Correios::Orders.get_stock(product.sku)

      unless correios_response.success?
        error_msg = "Erro ao consultar estoque do produto #{product.sku}: #{correios_response.code}"
        puts error_msg

        @stats[:failed] += 1
        record_error(error_msg)

        return
      end

      stock_data = JSON.parse(correios_response.body)
      available_stock = stock_data['disponivel'].to_i

      puts "Estoque disponível nos Correios para #{product.sku}: #{available_stock}"

      if update_shopify_inventory(product, available_stock)
        @stats[:success] += 1
      else
        @stats[:failed] += 1
      end
    rescue JSON::ParserError => e
      error_msg = "Erro ao parsear resposta dos Correios para #{product.sku}: #{e.message}"
      puts error_msg

      @stats[:failed] += 1
      record_error(error_msg)
    rescue StandardError => e
      error_msg = "Erro ao processar produto #{product.sku}: #{e.message}"
      puts error_msg

      @stats[:failed] += 1
      record_error(error_msg)
    end
  end

  def update_shopify_inventory(product, quantity)
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )

    location_id = ENV.fetch('LOCATION_LOG')

    begin
      update_inventory_quantity(session, product, quantity, location_id)

      puts "Estoque atualizado com sucesso para #{product.sku}: #{quantity} unidades"
      true
    rescue ShopifyAPI::Errors::HttpResponseError => e
      error_msg = "Erro da API Shopify para produto #{product.sku}: #{e.message}"
      puts error_msg

      record_error(error_msg)
      false
    rescue StandardError => e
      error_msg = "Erro ao atualizar Shopify para produto #{product.sku}: #{e.message}"
      puts error_msg

      record_error(error_msg)
      false
    end
  end

  def update_inventory_quantity(session, product, quantity, location_id)
    mutation = <<~GRAPHQL
      mutation inventorySetOnHandQuantities($input: InventorySetOnHandQuantitiesInput!) {
        inventorySetOnHandQuantities(input: $input) {
          inventoryAdjustmentGroup {
            id
            createdAt
            reason
          }
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    input = {
      reason: 'correction',
      setQuantities: [
        {
          inventoryItemId: shopify_inventory_item_gid(product.shopify_inventory_item_id),
          locationId: shopify_location_gid(location_id),
          quantity:
        }
      ]
    }

    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
    response = client.query(query: mutation, variables: { input: })

    user_errors = response.body.dig('data', 'inventorySetOnHandQuantities', 'userErrors') || []

    if response.body['errors'] || user_errors.any?
      error_msg = response.body['errors'] || user_errors
      raise StandardError, "Erro GraphQL: #{compact_graphql_error(error_msg)}"
    end

    update_local_stock_record(product, quantity)
  end

  def update_local_stock_record(product, quantity)
    product.update(stock_correios: quantity) if product.respond_to?(:stock_correios)
  end

  def shopify_inventory_item_gid(value)
    value = value.to_s.strip

    return value if value.start_with?('gid://shopify/InventoryItem/')

    "gid://shopify/InventoryItem/#{value}"
  end

  def shopify_location_gid(value)
    value = value.to_s.strip

    return value if value.start_with?('gid://shopify/Location/')

    "gid://shopify/Location/#{value}"
  end

  def compact_graphql_error(error)
    truncate(error.to_s, MAX_ERROR_LENGTH)
  end

  def record_error(message)
    @stats[:errors] ||= []
    @stats[:omitted_errors] ||= 0

    if @stats[:errors].size < MAX_STORED_ERRORS
      @stats[:errors] << truncate(message.to_s, MAX_ERROR_LENGTH)
    else
      @stats[:omitted_errors] += 1
    end
  end

  def stats_payload
    {
      total: @stats[:total],
      success: @stats[:success],
      failed: @stats[:failed],
      stored_errors: @stats[:errors].size,
      omitted_errors: @stats[:omitted_errors],
      errors: @stats[:errors]
    }
  end

  def safe_update_attempt!(attributes)
    @attempt.update!(attributes)
  rescue ActiveRecord::ValueTooLong => e
    puts "Erro ao salvar Attempt completo: #{e.message}"

    @attempt.reload

    fallback_attributes = attributes.except(:params)
    fallback_attributes[:message] = truncate(fallback_attributes[:message].to_s, MAX_MESSAGE_LENGTH) if fallback_attributes[:message]
    fallback_attributes[:error] = truncate(fallback_attributes[:error].to_s, MAX_MESSAGE_LENGTH) if fallback_attributes[:error]

    @attempt.update!(fallback_attributes)
  rescue StandardError => e
    puts "Erro ao atualizar Attempt: #{e.class}: #{e.message}"
  end

  def truncate(value, max_length)
    value = value.to_s

    return value if value.length <= max_length

    "#{value[0, max_length]}..."
  end
end