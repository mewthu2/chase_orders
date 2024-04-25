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
    @get_tracking = Attempt.where(kinds: :send_xml, status: 2)
                           .distinct(:order_correios_id)
                           .where.not(order_correios_id: Attempt.where(kinds: :get_tracking, status: 2).pluck(:order_correios_id))
    @get_tracking.each do |att|
      get_one_tracking(att)
    end
  end

  def get_one_tracking(att)
    # Get tracking
    begin
      attempt = Attempt.create(kinds: :get_tracking)
      tracking = Correios::Orders.get_tracking(att.order_correios_id)
    rescue StandardError => e
      attempt.update(error: e, status: :error, message: 'Erro na solicitação de rastreio aos Correios')
    end

    # Get order
    begin
      order = Tiny::Orders.obtain_order(att.tiny_order_id)
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
        send = Tiny::Orders.send_tracking(att.tiny_order_id, tracking['rastreio'][0]['codigoObjeto'])
      rescue StandardError => e
        attempt.update(error: e, status: :error, message: 'Erro no envio de rastreio ao Tiny')
      end
      attempt.update(message: send)

      begin
        Tiny::Orders.change_situation(att.tiny_order_id, 'Enviado') if order['pedido']['situacao'] == 'Faturado'
      rescue StandardError => e
        attempt.update(error: e, status: :error, message: 'Erro no envio de rastreio ao Tiny')
      end

    else
      attempt.update(status: :error, error: 'Correios ainda não disponibilizou o código de rastreio')

      # Returns the object to the queue
      att.destroy
    end
  end
end
