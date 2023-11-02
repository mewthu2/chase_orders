class GetTrackingJob < ActiveJob::Base
  def perform(param, att)
    case param
    when 'all'
      get_all_tracking
    when 'one'
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

    if tracking['rastreio'][0].present?
      attempt.update(tracking: tracking['rastreio'][0]['codigoObjeto'],
                     order_correios_id: att.order_correios_id,
                     id_nota_fiscal: att.id_nota_fiscal,
                     tiny_order_id: att.tiny_order_id)
    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')

      # Returns the object to the queue
      att.destroy
    end
  end
end