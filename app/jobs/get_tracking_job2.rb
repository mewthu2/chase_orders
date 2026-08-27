class GetTrackingJob2 < ActiveJob::Base
  def perform(param, att, marker_id = nil)
    case param
    when 'all'
      pull_all_tracking
    when 'one'
      get_one_tracking(att)
    end

    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end

  def pull_all_tracking
    tracked_ids = Attempt.where(kinds: :get_tracking_tiny2, status: :success).pluck(:order_correios_id)

    latest_ids = Attempt.where(kinds: :send_xml_tiny2, status: :success, is_transportadora: false)
                        .where.not(order_correios_id: tracked_ids)
                        .select('MAX(id) AS id')
                        .group(:order_correios_id)

    @get_tracking = Attempt.where(id: latest_ids.map(&:id))
    @get_tracking.each do |att|
      get_one_tracking(att)
    end
  end

  def get_one_tracking(att)
    begin
      attempt = Attempt.create(kinds: :get_tracking_tiny2, is_transportadora: att.is_transportadora)
      tracking = Correios::Orders.get_tracking(att.order_correios_id, is_transportadora: att.is_transportadora)
    rescue StandardError => e
      attempt.update(error: e, status: :error, message: 'Erro na solicitação de rastreio aos Correios')
    end

    begin
      order = Tiny::Orders.obtain_order(ENV.fetch('TOKEN_TINY2_PRODUCTION'), att.tiny_order_id)
    rescue StandardError => e
      attempt.update(error: e, status: :error, message: 'Erro na solicitação de pedido ao Tiny')
    end

    if tracking.present? && tracking['rastreio'].present? && tracking['rastreio'][0].present?
      attempt.update(tracking: tracking['rastreio'][0]['codigoObjeto'],
                     order_correios_id: att.order_correios_id,
                     id_nota_fiscal: att.id_nota_fiscal,
                     tiny_order_id: att.tiny_order_id,
                     status: :success)
      begin
        send = Tiny::Orders.send_tracking(att.tiny_order_id, tracking['rastreio'][0]['codigoObjeto'], ENV.fetch('TOKEN_TINY2_PRODUCTION'))
      rescue StandardError => e
        attempt.update(error: e, status: :error, message: 'Erro no envio de rastreio ao Tiny')
      end
      attempt.update(message: send)

      begin
        Tiny::Orders.change_situation(att.tiny_order_id, 'Enviado', ENV.fetch('TOKEN_TINY2_PRODUCTION')) if order['pedido']['situacao'] == 'Faturado'
      rescue StandardError => e
        attempt.update(error: e, status: :error, message: 'Erro no envio de rastreio ao Tiny')
      end

      Attempt.where(tiny_order_id: att.tiny_order_id).update_all(xml_nota: nil)
    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')
    end
  end
end
