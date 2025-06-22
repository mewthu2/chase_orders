class LogService
  def self.create_log(user:, resource_type:, action_type:, resource_name: nil, resource_id: nil, 
                     details: {}, old_values: {}, new_values: {}, request: nil, 
                     error_message: nil, success: true)
    
    log_params = {
      user: user,
      resource_type: resource_type.to_s,
      action_type: action_type.to_s,
      resource_name: resource_name,
      resource_id: resource_id,
      details: details.present? ? details.to_json : nil,
      old_values: old_values.present? ? old_values.to_json : nil,
      new_values: new_values.present? ? new_values.to_json : nil,
      error_message: error_message,
      success: success
    }

    if request
      log_params[:ip_address] = request.remote_ip
      log_params[:user_agent] = request.user_agent
    end

    Log.create!(log_params)
  rescue => e
    Rails.logger.error "Erro ao criar log: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  # Métodos específicos para diferentes tipos de recursos
  def self.log_discount_action(user:, action:, coupon_code:, price_rule_id: nil, 
                              old_values: {}, new_values: {}, details: {}, 
                              request: nil, error: nil)
    create_log(
      user: user,
      resource_type: 'discount',
      action_type: action,
      resource_name: coupon_code,
      resource_id: price_rule_id,
      old_values: old_values,
      new_values: new_values,
      details: details,
      request: request,
      error_message: error&.message,
      success: error.nil?
    )
  end

  def self.log_product_action(user:, action:, product_name:, product_id: nil, 
                             old_values: {}, new_values: {}, details: {}, 
                             request: nil, error: nil)
    create_log(
      user: user,
      resource_type: 'product',
      action_type: action,
      resource_name: product_name,
      resource_id: product_id,
      old_values: old_values,
      new_values: new_values,
      details: details,
      request: request,
      error_message: error&.message,
      success: error.nil?
    )
  end

  def self.log_order_action(user:, action:, order_name:, order_id: nil, 
                           old_values: {}, new_values: {}, details: {}, 
                           request: nil, error: nil)
    create_log(
      user: user,
      resource_type: 'order',
      action_type: action,
      resource_name: order_name,
      resource_id: order_id,
      old_values: old_values,
      new_values: new_values,
      details: details,
      request: request,
      error_message: error&.message,
      success: error.nil?
    )
  end
end