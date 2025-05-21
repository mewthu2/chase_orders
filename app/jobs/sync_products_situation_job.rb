class SyncProductsSituationJob < ActiveJob::Base
  LOCATIONS = {
    lagoa_seca: ENV.fetch('LOCATION_LAGOA_SECA'),
    bh_shopping: ENV.fetch('LOCATION_BH_SHOPPING'),
    rj: ENV.fetch('LOCATION_BARRA_SHOPPING')
  }.freeze

  BATCH_SIZE = 200

  def perform(location)
    unless LOCATIONS.key?(location.to_sym)
      raise ArgumentError, "Invalid location: #{location}. Valid options are: #{LOCATIONS.keys.join(', ')}"
    end

    motor = start_motor_tracking(location)

    begin
      sync_tiny_products(location)
      sync_shopify_products
      Tiny::Products.list_all_products('tiny_2', '', 'update_products_situation', '')
      sync_shopify_fields
      sync_shopify_inventory(location)
      sync_shopify_costs

      finish_motor_tracking(motor)
    rescue StandardError => e
      Rails.logger.error("Error in SyncProductsSituationJob for #{location}: #{e.message}\n#{e.backtrace.join("\n")}")
      finish_motor_tracking(motor, error: e.message)
      raise e
    end
  end

  private

  def sync_tiny_products(location)
    Tiny::Products.list_all_products(location.to_s, '', 'update_products_situation', '')
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_shopify_fields
    %w[shopify_product_id price_and_title variant_id cost].each do |action|
      Shopify::Products.sync_shopify_data_on_product(action)
    end
  end

  def sync_shopify_inventory(location)
    shopify_location_id = LOCATIONS[location.to_sym]
    Shopify::Products.update_inventory_for_location(location, shopify_location_id)
  end

  def start_motor_tracking(location)
    motor = Motor.find_or_initialize_by(job_name: "Atualização de produtos - #{location}")
    motor.start_time = Time.current
    motor.end_time = nil
    motor.running_time = nil
    motor.step = 'started'
    motor.save!
    motor
  end

  def finish_motor_tracking(motor, error: nil)
    return unless motor.present?

    motor.end_time = Time.current
    motor.running_time = (motor.end_time - motor.start_time).to_i
    motor.link = error.present? ? "Error: #{error}" : nil
    motor.step = error.present? ? 'error' : 'finished'
    motor.save!
  end
end