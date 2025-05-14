class SyncProductsSituationJob < ActiveJob::Base
  SHOPIFY_LOCATION_IDS = {
    lagoa_seca: ENV.fetch('LOCATION_LAGOA_SECA'),
    bh_shopping: ENV.fetch('LOCATION_BH_SHOPPING'),
    rj: ENV.fetch('LOCATION_BARRA_SHOPPING')
  }.freeze

  BATCH_SIZE = 200

  def perform
    motor = start_motor_tracking

    begin
      sync_tiny_products
      sync_shopify_products
      sync_shopify_fields
      sync_shopify_inventory_by_location
      sync_shopify_costs

      finish_motor_tracking(motor)
    rescue StandardError => e
      Rails.logger.error("Error in SyncProductsSituationJob: #{e.message}")
      finish_motor_tracking(motor, error: e.message)
      raise e
    end
  end

  def sync_tiny_products
    SHOPIFY_LOCATION_IDS.each_key do |location|
      Tiny::Products.list_all_products(location.to_s, '', 'update_products_situation', '')
    end
    Tiny::Products.list_all_products('tiny_2', '', 'update_products_situation', '')
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_shopify_fields
    %w[shopify_product_id price_and_title variant_id cost].each do |action|
      Shopify::Products.sync_shopify_data_on_product(action)
    end
  end

  def sync_shopify_inventory_by_location
    SHOPIFY_LOCATION_IDS.each do |tiny_location, shopify_location_id|
      Shopify::Products.update_inventory_for_location(tiny_location, shopify_location_id)
    end
  end

  private

  def start_motor_tracking
    motor = Motor.find_or_initialize_by(job_name: 'Atualização de produtos')
    motor.start_time = Time.current
    motor.end_time = nil
    motor.running_time = nil
    motor.step = 'started'
    motor.save!
    motor
  end

  def finish_motor_tracking(motor, error: nil)
    return unless motor.present?

    end_time = Time.current
    motor.end_time = end_time
    motor.running_time = (end_time - motor.start_time).to_i
    motor.link = error.present? ? "Error: #{error}" : nil
    motor.step = error.present? ? 'error' : 'finished'
    motor.save!
  end
end