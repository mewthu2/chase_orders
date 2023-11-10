class InvoiceEmitionsJob < ActiveJob::Base
  def perform(param, att)
    case param
    when 'all'
      all_emissions
    when 'one'
      one_emission(att)
    end
  end

  def all_emissions
    distinct_attempts = Attempt.where(kinds: :create_correios_order, status: 2).distinct(:order_correios_id)

    existing_emission_attempts = Attempt.where(kinds: :emission_invoice, status: 2, order_correios_id: distinct_attempts.pluck(:order_correios_id))

    attempts_to_emission = distinct_attempts.where.not(order_correios_id: existing_emission_attempts.pluck(:order_correios_id))
    attempts_to_emission.each do |att|
      one_emission(att)
    end
  end

  def one_emission(att)
    attempt = Attempt.create(kinds: :emission_invoice)

    begin
      response = Tiny::Invoices.invoice_emition(att.id_nota_fiscal.to_s)
      case response.code
      when 200
        if response.include?('A nota fiscal não foi enviada') || response.include?('porém apenas notas pendentes')
          attempt.update(
            order_correios_id: att.order_correios_id,
            id_nota_fiscal: att.id_nota_fiscal,
            tiny_order_id: att.tiny_order_id,
            status_code: response.code,
            message: response.message.first(100),
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
        attempt.update(error: "Unexpected response code: #{response.code}", status: :error)
      end
    rescue StandardError => e
      attempt.update(error: e.message.first(100), status: :error)
    end
  end
end