class UpdateShopifyStockFromCorreiosBatchJob < ActiveJob::Base
  MAX_STORED_ERRORS = 50
  MAX_ERROR_LENGTH = 500
  MAX_MESSAGE_LENGTH = 1_000

  def perform(attempt_id, product_ids, batch_index, total_batches)
    @attempt = Attempt.find(attempt_id)
    @batch_index = batch_index
    @total_batches = total_batches
    @stats = {
      success: 0,
      failed: 0,
      errors: [],
      omitted_errors: 0
    }

    return if batch_already_completed?

    puts "Iniciando lote #{@batch_index}/#{@total_batches} com #{product_ids.size} produto(s)."

    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )

    @shopify_client = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
    @location_id = ENV.fetch('LOCATION_LOG')

    Product.where(id: product_ids).find_each.with_index(1) do |product, index|
      update_product_stock(product, index, product_ids.size)
    end

    finish_batch!

    puts "Lote #{@batch_index}/#{@total_batches} finalizado. Sucesso: #{@stats[:success]}, falhas: #{@stats[:failed]}."
  rescue StandardError => e
    error_message = "Erro fatal no lote #{@batch_index}/#{@total_batches}: #{e.class}: #{e.message}"
    puts error_message

    record_error(error_message)
    finish_batch!

    nil
  end

  private

  def update_product_stock(product, current_index, total)
    puts "[Lote #{@batch_index}/#{@total_batches}] [#{current_index}/#{total}] Processando produto: #{product.sku}"

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
    begin
      update_inventory_quantity(product, quantity)

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

  def update_inventory_quantity(product, quantity)
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
          locationId: shopify_location_gid(@location_id),
          quantity: quantity
        }
      ]
    }

    response = @shopify_client.query(query: mutation, variables: { input: input })

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

  def finish_batch!
    @attempt.with_lock do
      payload = current_attempt_payload

      payload['completed_batch_indexes'] ||= []
      payload['errors'] ||= []
      payload['omitted_errors'] ||= 0

      return if payload['completed_batch_indexes'].include?(@batch_index)

      payload['success'] = payload['success'].to_i + @stats[:success].to_i
      payload['failed'] = payload['failed'].to_i + @stats[:failed].to_i
      payload['processed_batches'] = payload['processed_batches'].to_i + 1
      payload['completed_batch_indexes'] << @batch_index

      @stats[:errors].each do |error|
        if payload['errors'].size < MAX_STORED_ERRORS
          payload['errors'] << error
        else
          payload['omitted_errors'] = payload['omitted_errors'].to_i + 1
        end
      end

      payload['omitted_errors'] = payload['omitted_errors'].to_i + @stats[:omitted_errors].to_i

      if payload['processed_batches'].to_i >= payload['total_batches'].to_i
        final_message = if payload['failed'].to_i.positive?
                          "Sincronização concluída com erros: #{payload['success']}/#{payload['total']} produtos atualizados. #{payload['failed']} falharam."
                        else
                          "Sincronização concluída! #{payload['success']}/#{payload['total']} produtos atualizados com sucesso."
                        end

        @attempt.update!(
          status: :success,
          message: final_message,
          params: safe_json(payload)
        )
      else
        @attempt.update!(
          status: :processing,
          message: "Sincronização em andamento: #{payload['processed_batches']}/#{payload['total_batches']} lote(s) concluído(s).",
          params: safe_json(payload)
        )
      end
    end
  rescue ActiveRecord::ValueTooLong => e
    puts "Erro ao salvar params do Attempt: #{e.message}"

    @attempt.reload
    @attempt.update!(
      message: "Sincronização em andamento. Lote #{@batch_index}/#{@total_batches} finalizado, mas params ficou grande demais."
    )
  end

  def batch_already_completed?
    payload = current_attempt_payload
    completed = payload['completed_batch_indexes'] || []

    completed.include?(@batch_index)
  end

  def current_attempt_payload
    JSON.parse(@attempt.params.presence || '{}')
  rescue JSON::ParserError
    {}
  end

  def safe_json(payload)
    payload['errors'] = Array(payload['errors']).first(MAX_STORED_ERRORS)
    payload.to_json
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

  def compact_graphql_error(error)
    truncate(error.to_s, MAX_ERROR_LENGTH)
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

  def truncate(value, max_length)
    value = value.to_s

    return value if value.length <= max_length

    "#{value[0, max_length]}..."
  end
end