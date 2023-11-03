class GetTrackingJob < ActiveJob::Base
  def perform(param, att)
    case param
    when 'all'
      pull_all_tracking
    when 'one'
      get_one_tracking(att)
    end
  end

  def pull_all_tracking
    Attempt.where(kinds: :send_xml, status: 2).each do |att|
      next if Attempt.find_by(kinds: :get_tracking, status: 2, order_correios_id: att.order_correios_id).present?
      get_one_tracking(att)
    end
  end

  def get_one_tracking(att)
    begin
      attempt = Attempt.create(kinds: :get_tracking)
      tracking = Correios::Orders.get_tracking(att.order_correios_id)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if tracking['rastreio'].present? && tracking['rastreio'][0].present?
      attempt.update(tracking: tracking['rastreio'][0]['codigoObjeto'],
                     order_correios_id: att.order_correios_id,
                     id_nota_fiscal: att.id_nota_fiscal,
                     tiny_order_id: att.tiny_order_id,
                     status: :success)
      begin
        send = Tiny::Orders.send_tracking(att.tiny_order_id, tracking['rastreio'][0]['codigoObjeto'])
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end
      attempt.update(message: send)
    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')

      # Returns the object to the queue
      att.destroy
    end
  end
end