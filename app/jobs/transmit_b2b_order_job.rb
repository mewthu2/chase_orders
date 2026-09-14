class TransmitB2bOrderJob < ActiveJob::Base
  queue_as :default

  def perform(b2b_order_id)
    order = B2bOrder.find(b2b_order_id)
    service = B2bTinyService.new

    result = order.sale? ? service.create_sale_order(order) : service.create_stock_transfer(order)

    if result[:success]
      order.update!(status: :transmitted, tiny_reference_id: result[:tiny_reference_id], tiny_reference_number: result[:tiny_reference_number])
    else
      order.update!(status: :error, error_message: result[:error])
    end
  end
end
