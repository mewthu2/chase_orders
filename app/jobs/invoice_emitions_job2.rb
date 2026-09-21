class InvoiceEmitionsJob2 < ActiveJob::Base
  def perform(param, att, marker_id = nil)
    # return unless ScheduleUtils.within_schedule?

    case param
    when 'all'
      all_emissions
    when 'one'
      one_emission(att)
    end

    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end

  def all_emissions
    successful_ids = Attempt.where(kinds: :emission_invoice_tiny2, status: :success)
                            .pluck(:order_correios_id)
                            .compact
    @invoice_emition = Attempt.where(kinds: :create_correios_order_tiny2, status: :success)
                              .where.not(order_correios_id: successful_ids)
                              .distinct(:order_correios_id)
    @invoice_emition.each do |att|
      one_emission(att)
    end
  end

  def one_emission(att)
    attempt = Attempt.create(kinds: :emission_invoice_tiny2, is_transportadora: att.is_transportadora)

    begin
      response = Tiny::Invoices.invoice_emition(att.id_nota_fiscal.to_s, ENV.fetch('TOKEN_TINY2_PRODUCTION'))
      case response.code
      when 200
        body = response.body.to_s

        if body.include?('<status>Erro</status>')
          error_message = body[/<erro>(.*?)<\/erro>/m, 1]

          attempt.update(
            order_correios_id: att.order_correios_id,
            id_nota_fiscal: att.id_nota_fiscal,
            tiny_order_id: att.tiny_order_id,
            status_code: response.code,
            message: error_message.to_s.first(100),
            status: error_message == 'Nota Fiscal localizada, porém apenas notas pendentes ou rejeitadas podem ser enviadas' ? :success : :error
          )
        elsif body.include?('A nota fiscal não foi enviada')
          attempt.update(
            order_correios_id: att.order_correios_id,
            id_nota_fiscal: att.id_nota_fiscal,
            tiny_order_id: att.tiny_order_id,
            status_code: response.code,
            message: response.message.to_s.first(100),
            status: :error
          )
        else
          attempt.update(
            order_correios_id: att.order_correios_id,
            id_nota_fiscal: att.id_nota_fiscal,
            tiny_order_id: att.tiny_order_id,
            status_code: response.code,
            status: :success
          )
        end
      else
        attempt.update(error: "Código de resposta inesperado: #{response.code}", status: :error)
      end
    rescue StandardError => e
      attempt.update(error: e.message.first(100), status: :error)
    end

    attempt
  end
end
