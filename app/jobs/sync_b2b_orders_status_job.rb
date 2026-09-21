class SyncB2bOrdersStatusJob < ActiveJob::Base
  queue_as :default

  def perform
    service = B2bTinyService.new

    B2bOrder.sale.where.not(tiny_reference_id: [nil, '']).find_each do |order|
      result = service.order_status(order.tiny_reference_id)
      next unless result

      new_status = B2bOrder::TINY_SITUATION_MAP[result[:situacao]]
      next unless new_status

      attrs = { status: new_status }
      attrs[:tracking_code] = result[:tracking_code] if result[:tracking_code].present?
      order.update(attrs)
    end
  end
end
