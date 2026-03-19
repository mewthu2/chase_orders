class TinyIntegrationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(order_pdv_id)
    order_pdv = OrderPdv.includes(:order_pdv_items, :order_parcels, :client).find(order_pdv_id)

    Rails.logger.info "TinyIntegrationJob starting | order_pdv_id: #{order_pdv_id}"

    service = TinyService.new
    result  = service.create_order(order_pdv)

    if result[:success]
      order_pdv.update_columns(
        tiny_order_id:     result[:tiny_order_id],
        tiny_order_number: result[:tiny_order_number],
        tiny_status:       'aberto',
        tiny_integrated_at: Time.current,
        tiny_error:        nil
      )
      Rails.logger.info "TinyIntegrationJob success | tiny_order_id: #{result[:tiny_order_id]}"
    else
      order_pdv.update_columns(
        tiny_status: 'error',
        tiny_error:  result[:error]
      )
      Rails.logger.error "TinyIntegrationJob failed | error: #{result[:error]}"
      raise "Tiny integration failed: #{result[:error]}"
    end
  end
end
