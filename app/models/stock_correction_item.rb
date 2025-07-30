class StockCorrectionItem < ApplicationRecord
  belongs_to :stock_correction
  belongs_to :product

  validates :product_id, uniqueness: { scope: :stock_correction_id }
  validates :corrected_stock, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: :needs_correction?
  validates :correction_reason, presence: true, if: :needs_correction?

  before_save :set_current_stock, if: :new_record?

  def execute_correction!
    Rails.logger.info "=== Starting execute_correction! for item #{id} ==="
    Rails.logger.info "needs_correction?: #{needs_correction?}"
    Rails.logger.info "executed?: #{executed?}"
    Rails.logger.info "corrected_stock: #{corrected_stock}"
    Rails.logger.info "correction_reason: #{correction_reason}"
    
    unless needs_correction?
      Rails.logger.error "Item does not need correction"
      return false
    end
    
    if executed?
      Rails.logger.error "Item already executed"
      return false
    end
    
    if corrected_stock.blank?
      Rails.logger.error "Corrected stock is blank"
      return false
    end
    
    if correction_reason.blank?
      Rails.logger.error "Correction reason is blank"
      return false
    end
    
    location = stock_correction.location
    Rails.logger.info "Location: #{location}"
    Rails.logger.info "Product ID: #{product.id}"
    Rails.logger.info "Product SKU: #{product.sku}"
    
    begin
      Rails.logger.info "Executing correction for product #{product.sku}: #{current_stock} -> #{corrected_stock} in #{location}"
      
      # Verificar se o produto existe e tem os campos necessários
      unless product
        Rails.logger.error "Product not found"
        return false
      end
      
      # Atualizar estoque no banco local
      case location
      when 'lagoa_seca'
        Rails.logger.info "Updating stock_lagoa_seca from #{product.stock_lagoa_seca} to #{corrected_stock}"
        product.update!(stock_lagoa_seca: corrected_stock)
        Rails.logger.info "Updated stock_lagoa_seca to #{corrected_stock}"
      when 'bh_shopping'
        Rails.logger.info "Updating stock_bh_shopping from #{product.stock_bh_shopping} to #{corrected_stock}"
        product.update!(stock_bh_shopping: corrected_stock)
        Rails.logger.info "Updated stock_bh_shopping to #{corrected_stock}"
      when 'rj'
        Rails.logger.info "Updating stock_rj from #{product.stock_rj} to #{corrected_stock}"
        product.update!(stock_rj: corrected_stock)
        Rails.logger.info "Updated stock_rj to #{corrected_stock}"
      else
        Rails.logger.error "Unknown location: #{location}"
        return false
      end
      
      # Recarregar o produto para verificar se foi atualizado
      product.reload
      Rails.logger.info "Product reloaded, checking updated values..."
      
      case location
      when 'lagoa_seca'
        Rails.logger.info "Current stock_lagoa_seca: #{product.stock_lagoa_seca}"
      when 'bh_shopping'
        Rails.logger.info "Current stock_bh_shopping: #{product.stock_bh_shopping}"
      when 'rj'
        Rails.logger.info "Current stock_rj: #{product.stock_rj}"
      end
      
      # Marcar como executado
      Rails.logger.info "Marking item as executed..."
      update_result = update!(executed: true, executed_at: Time.current)
      Rails.logger.info "Update result: #{update_result}"
      Rails.logger.info "Item executed status: #{executed?}"
      Rails.logger.info "Item executed_at: #{executed_at}"
      
      Rails.logger.info "Correction executed successfully for #{product.sku}"
      
      true
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "ActiveRecord::RecordInvalid in execute_correction!: #{e.message}"
      Rails.logger.error "Record errors: #{e.record.errors.full_messages.join(', ')}"
      false
    rescue => e
      Rails.logger.error "Error executing correction for #{product.sku}: #{e.message}"
      Rails.logger.error "Error class: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      false
    end
  end

  def sync_with_shopify!
    return false unless needs_correction? && executed?
    return false unless product.shopify_inventory_item_id.present?
    
    begin
      location = stock_correction.location
      
      Rails.logger.info "Starting Shopify sync for #{product.sku} (inventory_item_id: #{product.shopify_inventory_item_id})"
      Rails.logger.info "Location: #{location}, Shopify Location ID: #{get_shopify_location_id(location)}"
      
      # Marcar como sincronizando
      update!(shopify_sync_status: 'syncing')
      
      # Usar o método correto do ShopifyInventoryService
      result = ShopifyInventoryService.update_inventory(product, location, corrected_stock, 'correction')
      
      if result[:success]
        update!(
          last_shopify_sync_at: Time.current,
          shopify_sync_status: 'synced',
          shopify_sync_error: nil
        )
        Rails.logger.info "Shopify sync successful for #{product.sku}: #{corrected_stock} units"
        true
      else
        update!(
          shopify_sync_status: 'error',
          shopify_sync_error: result[:message]
        )
        Rails.logger.error "Shopify sync failed for #{product.sku}: #{result[:message]}"
        false
      end
    rescue => e
      update!(
        shopify_sync_status: 'error',
        shopify_sync_error: e.message
      )
      Rails.logger.error "Shopify sync exception for #{product.sku}: #{e.message}"
      false
    end
  end

  def shopify_sync_status_badge_class
    case shopify_sync_status
    when 'synced'
      'bg-success'
    when 'error'
      'bg-danger'
    when 'syncing'
      'bg-warning'
    else
      'bg-secondary'
    end
  end

  def shopify_sync_status_text
    case shopify_sync_status
    when 'synced'
      'Sincronizado'
    when 'error'
      'Erro'
    when 'syncing'
      'Sincronizando'
    else
      'Pendente'
    end
  end

  private

  def set_current_stock
    location = stock_correction.location
    self.current_stock = case location
                        when 'lagoa_seca'
                          product.stock_lagoa_seca&.to_i || 0
                        when 'bh_shopping'
                          product.stock_bh_shopping&.to_i || 0
                        when 'rj'
                          product.stock_rj&.to_i || 0
                        else
                          0
                        end
  end

  def get_shopify_location_id(location)
    # Mapear suas locations para os IDs corretos da Shopify
    case location
    when 'lagoa_seca'
      ENV.fetch('LOCATION_LAGOA_SECA', nil) # 72286994506
    when 'bh_shopping'
      ENV.fetch('LOCATION_BH_SHOPPING', nil) # 72286699594
    when 'rj'
      ENV.fetch('LOCATION_BARRA_SHOPPING', nil) # 72287027274
    else
      ENV.fetch('LOCATION_LAGOA_SECA', nil) # Default para Lagoa Seca
    end
  end
end
