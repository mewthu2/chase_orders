class InvoiceEmitionsJob < ActiveJob::Base
  def perform(param)
    case param
    when 'all'
      all_emissions
    when 'one'
      one_emission(att)
    end
  end

  def all_emissions
    Attempt.where(kinds: :create_correios_order, status: 2).distinct(:order_correios_id).each do |att|
      next if Attempt.find_by(kinds: :emission_invoice, status: 2, order_correios_id: att.order_correios_id).present?
      one_emission(att)
    end
  end

  def one_emission(att)
    attempt = Attempt.create(kinds: :emission_invoice)

    begin
      response = Tiny::Invoices.invoice_emition(att.id_nota_fiscal.to_s)
      case response.code
      when 200
        attempt.update(
          order_correios_id: att.order_correios_id,
          id_nota_fiscal: att.id_nota_fiscal,
          tiny_order_id: att.tiny_order_id,
          status_code: response.code,
          message: response.body,
          status: :success
        )
      else
        attempt.update(error: "Unexpected response code: #{response.code}", status: :error)
      end
    rescue StandardError => e
      attempt.update(error: e.message, status: :error)
    end
  end
end