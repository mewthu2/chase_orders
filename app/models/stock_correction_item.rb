class StockCorrectionItem < ApplicationRecord
  belongs_to :stock_correction
  belongs_to :product

  validates :product_id, uniqueness: { scope: :stock_correction_id }
  validates :corrected_stock, presence: true, numericality: { greater_than_or_equal_to: 0 }, if: :needs_correction?
  validates :correction_reason, presence: true, if: :needs_correction?

  before_save :set_current_stock, if: :new_record?
  before_save :set_stock_before, if: :will_save_change_to_corrected_stock?

  def execute_correction!(with_shopify_integration: false)
    Rails.logger.info "=== Starting execute_correction! for item #{id} ==="
    Rails.logger.info "needs_correction?: #{needs_correction?}"
    Rails.logger.info "executed?: #{executed?}"
    Rails.logger.info "corrected_stock: #{corrected_stock}"
    Rails.logger.info "correction_reason: #{correction_reason}"
    Rails.logger.info "with_shopify_integration: #{with_shopify_integration}"

    if executed?
      Rails.logger.error 'Item already executed'
      return false
    end

    location = stock_correction.location
    Rails.logger.info "Location: #{location}"
    Rails.logger.info "Product ID: #{product.id}"
    Rails.logger.info "Product SKU: #{product.sku}"

    begin
      Rails.logger.info "Executing correction for product #{product.sku}: #{current_stock} -> #{corrected_stock} in #{location}"

      unless product
        Rails.logger.error 'Product not found'
        return false
      end

      case location
      when 'lagoa_seca'
        product.update!(stock_lagoa_seca: corrected_stock)
      when 'bh_shopping'
        product.update!(stock_bh_shopping: corrected_stock)
      when 'rj'
        product.update!(stock_rj: corrected_stock)
      when 'fortaleza_rio_mar'
        product.update!(stock_fortaleza_rio_mar: corrected_stock)
      when 'porto_alegre_bourbon'
        product.update!(stock_porto_alegre_bourbon: corrected_stock)
      when 'eldorado_sp'
        product.update!(stock_eldorado_sp: corrected_stock)
      when 'iguatemi_campinas'
        product.update!(stock_iguatemi_campinas: corrected_stock)
      when 'shopping_analia_franco'
        product.update!(stock_shopping_analia_franco: corrected_stock)
      else
        Rails.logger.error "Unknown location: #{location}"
        return false
      end

      product.reload
      Rails.logger.info 'Product reloaded, checking updated values...'

      case location
      when 'lagoa_seca'
        Rails.logger.info "Current stock_lagoa_seca: #{product.stock_lagoa_seca}"
      when 'bh_shopping'
        Rails.logger.info "Current stock_bh_shopping: #{product.stock_bh_shopping}"
      when 'rj'
        Rails.logger.info "Current stock_rj: #{product.stock_rj}"
      when 'fortaleza_rio_mar'
        Rails.logger.info "Current stock_fortaleza_rio_mar: #{product.stock_fortaleza_rio_mar}"
      when 'porto_alegre_bourbon'
        Rails.logger.info "Current stock_porto_alegre_bourbon: #{product.stock_porto_alegre_bourbon}"
      when 'eldorado_sp'
        Rails.logger.info "Current stock_eldorado_sp: #{product.stock_eldorado_sp}"
      when 'iguatemi_campinas'
        Rails.logger.info "Current stock_iguatemi_campinas: #{product.stock_iguatemi_campinas}"
      when 'shopping_analia_franco'
        Rails.logger.info "Current stock_shopping_analia_franco: #{product.stock_shopping_analia_franco}"
      end

      Rails.logger.info 'Marking item as executed...'
      update_result = update!(executed: true, executed_at: Time.current)
      Rails.logger.info "Update result: #{update_result}"
      Rails.logger.info "Item executed status: #{executed?}"
      Rails.logger.info "Item executed_at: #{executed_at}"

      if with_shopify_integration
        Rails.logger.info '=== Starting Shopify Integration ==='
        if product.shopify_inventory_item_id.present?
          Rails.logger.info "Product has shopify_inventory_item_id: #{product.shopify_inventory_item_id}"

          update!(shopify_sync_status: 'syncing')

          result = ShopifyInventoryService.update_inventory(product, location, corrected_stock, 'correction')

          if result[:success]
            update!(
              last_shopify_sync_at: Time.current,
              shopify_sync_status: 'synced',
              shopify_sync_error: nil
            )
            Rails.logger.info "✅ Shopify integration successful for #{product.sku}: #{corrected_stock} units"
          else
            update!(
              shopify_sync_status: 'error',
              shopify_sync_error: result[:message]
            )
            Rails.logger.error "❌ Shopify integration failed for #{product.sku}: #{result[:message]}"
          end
        else
          Rails.logger.warn "⚠️ Product #{product.sku} has no shopify_inventory_item_id - skipping Shopify sync"
          update!(
            shopify_sync_status: 'no_shopify_id',
            shopify_sync_error: 'Produto sem shopify_inventory_item_id'
          )
        end
      else
        Rails.logger.info '⏭️ Shopify integration skipped (with_shopify_integration: false)'
        update!(shopify_sync_status: 'pending') if shopify_sync_status.blank?
      end

      Rails.logger.info "Correction executed successfully for #{product.sku}"

      true
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "ActiveRecord::RecordInvalid in execute_correction!: #{e.message}"
      Rails.logger.error "Record errors: #{e.record.errors.full_messages.join(', ')}"
      false
    rescue StandardError => e
      Rails.logger.error "Error executing correction for #{product.sku}: #{e.message}"
      Rails.logger.error "Error class: #{e.class}"
      Rails.logger.error e.backtrace.join("\n")
      false
    end
  end

  def sync_with_shopify!
    Rails.logger.info "=== Starting sync_with_shopify! for item #{id} ==="
    
    unless needs_correction?
      Rails.logger.warn "Item #{id} does not need correction"
      return false
    end

    unless executed?
      Rails.logger.warn "Item #{id} has not been executed yet"
      return false
    end

    unless product.shopify_inventory_item_id.present?
      Rails.logger.warn "Product #{product.sku} has no shopify_inventory_item_id"
      update!(
        shopify_sync_status: 'no_shopify_id',
        shopify_sync_error: 'Produto sem shopify_inventory_item_id'
      )
      return false
    end

    begin
      location = stock_correction.location

      Rails.logger.info "Syncing #{product.sku} (inventory_item_id: #{product.shopify_inventory_item_id})"
      Rails.logger.info "Location: #{location}, Stock: #{corrected_stock}"

      update!(shopify_sync_status: 'syncing')

      result = ShopifyInventoryService.update_inventory(product, location, corrected_stock, 'correction')

      if result[:success]
        update!(
          last_shopify_sync_at: Time.current,
          shopify_sync_status: 'synced',
          shopify_sync_error: nil
        )
        Rails.logger.info "✅ Shopify sync successful for #{product.sku}: #{corrected_stock} units"
        true
      else
        update!(
          shopify_sync_status: 'error',
          shopify_sync_error: result[:message]
        )
        Rails.logger.error "❌ Shopify sync failed for #{product.sku}: #{result[:message]}"
        false
      end
    rescue StandardError => e
      update!(
        shopify_sync_status: 'error',
        shopify_sync_error: e.message
      )
      Rails.logger.error "Exception during Shopify sync for #{product.sku}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
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

  def stock_comparison_text
    if needs_correction? && stock_before.present? && corrected_stock.present?
      "Antes: #{stock_before} / Corrigido: #{corrected_stock}"
    elsif needs_correction? && corrected_stock.present?
      "Corrigido: #{corrected_stock}"
    else
      '-'
    end
  end

  private

  def set_current_stock
    location = stock_correction.location
    self.current_stock = case location
                         when 'lagoa_seca'
                           product.stock_lagoa_seca&.to_i
                         when 'bh_shopping'
                           product.stock_bh_shopping&.to_i
                         when 'rj'
                           product.stock_rj&.to_i
                         when 'fortaleza_rio_mar'
                           product.stock_fortaleza_rio_mar&.to_i
                         when 'porto_alegre_bourbon'
                           product.stock_porto_alegre_bourbon&.to_i
                         when 'eldorado_sp'
                           product.stock_eldorado_sp&.to_i
                         else
                           0
                         end
  end

  def set_stock_before
    self.stock_before = current_stock || 0 if needs_correction? && corrected_stock.present? && stock_before.blank?
  end

  def get_shopify_location_id(location)
    case location
    when 'lagoa_seca'
      ENV.fetch('LOCATION_LAGOA_SECA')
    when 'bh_shopping'
      ENV.fetch('LOCATION_BH_SHOPPING')
    when 'rj'
      ENV.fetch('LOCATION_BARRA_SHOPPING')
    when 'fortaleza_rio_mar'
      ENV.fetch('LOCATION_FORTALEZA_RIO_MAR')
    when 'porto_alegre_bourbon'
      ENV.fetch('LOCATION_PORTO_ALEGRE_BOURBON')
    when 'eldorado_sp'
      ENV.fetch('LOCATION_ELDORADO_SP')
    when 'shopping_analia_franco'
      ENV.fetch('LOCATION_SHOPPING_ANALIA_FRANCO')
    when 'iguatemi_campinas'
      ENV.fetch('LOCATION_IGUATEMI_CAMPINAS')
    end
  end
end
