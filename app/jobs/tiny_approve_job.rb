class TinyApproveJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(order_pdv_id)
    order_pdv = OrderPdv.find(order_pdv_id)

    unless order_pdv.tiny_order_id.present?
      Rails.logger.warn "TinyApproveJob skipped — no tiny_order_id | order_pdv_id: #{order_pdv_id}"
      return
    end

    Rails.logger.info "TinyApproveJob starting | tiny_order_id: #{order_pdv.tiny_order_id}"

    service = TinyService.new
    result  = service.approve_order(order_pdv.tiny_order_id)

    if result[:success]
      order_pdv.update_columns(
        tiny_status: 'aprovado',
        status:      'paid',
        tiny_error:  nil
      )
      Rails.logger.info "TinyApproveJob success | order_pdv_id: #{order_pdv_id}"
    else
      order_pdv.update_columns(tiny_error: result[:error])
      Rails.logger.error "TinyApproveJob failed | error: #{result[:error]}"
      raise "Tiny approve failed: #{result[:error]}"
    end
  end
end
