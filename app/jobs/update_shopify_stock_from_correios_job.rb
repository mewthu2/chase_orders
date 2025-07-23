class UpdateShopifyStockFromCorreiosJob < ActiveJob::Base
  def perform(attempt_id = nil)
    @attempt = attempt_id ? Attempt.find(attempt_id) : create_new_attempt

    begin
      @attempt.update!(status: :processing, message: 'Iniciando sincronização...')

      puts 'Iniciando sincronização de estoque dos Correios para Shopify...'

      products = Product.where.not(sku: [nil, ''])
                        .where.not(shopify_inventory_item_id: [nil, ''])

      puts "Processando #{products.count} produto(s)..."

      @stats = { total: products.count, success: 0, failed: 0, errors: [] }

      products.each_with_index do |product, index|
        update_product_stock(product, index + 1)
        sleep(0.5)
      end

      success_message = "Sincronização concluída! #{@stats[:success]}/#{@stats[:total]} produtos atualizados com sucesso."
      @attempt.update!(
        status: :success,
        message: success_message,
        params: @stats.to_json
      )

      puts success_message

    rescue StandardError => e
      error_message = "Erro durante a sincronização: #{e.message}"
      @attempt.update!(
        status: :error,
        error: error_message,
        message: e.backtrace.join("\n")
      )
      puts error_message
      raise e
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
        @stats[:errors] << error_msg
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
      @stats[:errors] << error_msg
    rescue StandardError => e
      error_msg = "Erro ao processar produto #{product.sku}: #{e.message}"
      puts error_msg
      @stats[:failed] += 1
      @stats[:errors] << error_msg
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
      @stats[:errors] << error_msg
      false
    rescue StandardError => e
      error_msg = "Erro ao atualizar Shopify para produto #{product.sku}: #{e.message}"
      puts error_msg
      @stats[:errors] << error_msg
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
          inventoryItemId: "gid://shopify/InventoryItem/#{product.shopify_inventory_item_id}",
          locationId: "gid://shopify/Location/#{location_id}",
          quantity:
        }
      ]
    }

    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
    response = client.query(query: mutation, variables: { input: })

    user_errors = response.body.dig('data', 'inventorySetOnHandQuantities', 'userErrors') || []

    if response.body['errors'] || user_errors.any?
      error_msg = response.body['errors'] || user_errors
      raise StandardError, "Erro GraphQL: #{error_msg}"
    end

    update_local_stock_record(product, quantity)
  end

  def update_local_stock_record(product, quantity)
    product.update(stock_correios: quantity) if product.respond_to?(:stock_correios)
  end
end
