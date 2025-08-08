class SyncShopifyCorrectionsJob < ApplicationJob
  queue_as :default

  def perform(stock_correction_id, user_id)
    Rails.logger.info "=== Starting SyncShopifyCorrectionsJob ==="
    Rails.logger.info "Stock Correction ID: #{stock_correction_id}"
    Rails.logger.info "User ID: #{user_id}"

    stock_correction = StockCorrection.find(stock_correction_id)
    user = User.find(user_id)

    begin
      # Buscar itens que precisam ser sincronizados
      items_to_sync = stock_correction.stock_correction_items
                                    .where(needs_correction: true)
                                    .includes(:product)

      Rails.logger.info "Found #{items_to_sync.count} items to sync"

      if items_to_sync.empty?
        Rails.logger.info "No items to sync, completing integration"
        stock_correction.complete_integration!
        return
      end

      synced_count = 0
      error_count = 0
      errors = []

      items_to_sync.each do |item|
        begin
          Rails.logger.info "Processing item #{item.id} - Product: #{item.product.sku}"
          
          # Executar a correção se ainda não foi executada
          unless item.executed?
            Rails.logger.info "Executing correction for item #{item.id}"
            item.execute_correction!(with_shopify_integration: false)
          end

          # Sincronizar com Shopify
          if item.product.shopify_variant_id.present?
            Rails.logger.info "Syncing item #{item.id} with Shopify"
            
            result = ShopifyInventoryService.update_inventory(
              item.product,
              stock_correction.location,
              item.corrected_stock || item.current_stock,
              'correction'
            )

            if result[:success]
              item.update!(
                shopify_sync_status: 'synced',
                shopify_sync_error: nil,
                last_shopify_sync_at: Time.current
              )
              synced_count += 1
              Rails.logger.info "Successfully synced item #{item.id}"
            else
              item.update!(
                shopify_sync_status: 'error',
                shopify_sync_error: result[:message],
                last_shopify_sync_at: Time.current
              )
              error_count += 1
              errors << "#{item.product.sku}: #{result[:message]}"
              Rails.logger.error "Failed to sync item #{item.id}: #{result[:message]}"
            end
          else
            Rails.logger.warn "Item #{item.id} has no Shopify variant ID, skipping sync"
            item.update!(
              shopify_sync_status: 'no_shopify_id',
              shopify_sync_error: 'Produto não possui ID do Shopify',
              last_shopify_sync_at: Time.current
            )
          end

        rescue => e
          error_count += 1
          errors << "#{item.product.sku}: #{e.message}"
          Rails.logger.error "Error processing item #{item.id}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          
          item.update!(
            shopify_sync_status: 'error',
            shopify_sync_error: e.message,
            last_shopify_sync_at: Time.current
          )
        end
      end

      Rails.logger.info "Sync completed - Synced: #{synced_count}, Errors: #{error_count}"

      # Atualizar status da integração baseado nos resultados
      if error_count == 0
        stock_correction.complete_integration!
        Rails.logger.info "Integration completed successfully"
      else
        error_message = "#{error_count} erros encontrados: #{errors.first(3).join('; ')}"
        error_message += "..." if errors.count > 3
        stock_correction.fail_integration!(error_message)
        Rails.logger.error "Integration completed with errors: #{error_message}"
      end

      # TODO: Enviar notificação para o usuário (email, websocket, etc.)
      Rails.logger.info "Job completed for user #{user.name}"

    rescue => e
      Rails.logger.error "Critical error in SyncShopifyCorrectionsJob: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      # Marcar integração como erro
      stock_correction.fail_integration!("Erro crítico: #{e.message}")
      
      raise e
    end
  end
end
