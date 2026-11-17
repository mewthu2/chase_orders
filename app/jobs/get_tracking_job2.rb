class GetTrackingJob2 < ActiveJob::Base
  queue_as :correios_b2b
  include SingleRun
  runs_one_at_a_time if: ->(args) { args.first == 'all' }

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
  ensure
    # Pedidos feitos no Honey: o rastreio fica no próprio pedido.
    HoneyB2bLog.track_pending!
  end

  def get_one_tracking(att)
    begin
      attempt = Attempt.create(kinds: :get_tracking_tiny2, is_transportadora: att.is_transportadora)
      tracking = Correios::Orders.get_tracking(att.order_correios_id, from_tiny2: true)
    rescue StandardError => e
      attempt.update(error: e, status: :error, message: 'Erro na solicitação de rastreio aos Correios')
    end

    if tracking.present? && tracking['rastreio'].present? && tracking['rastreio'][0].present?
      attempt.update(tracking: tracking['rastreio'][0]['codigoObjeto'],
                     order_correios_id: att.order_correios_id,
                     id_nota_fiscal: att.id_nota_fiscal,
                     tiny_order_id: att.tiny_order_id,
                     status: :success)
      # O Tiny 2 não é mais usado: o código fica só no Honey.
      attempt.update(message: 'Rastreio gravado no Honey')

      Attempt.where(tiny_order_id: att.tiny_order_id).update_all(xml_nota: nil)
    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')
    end

    attempt
  end
end
