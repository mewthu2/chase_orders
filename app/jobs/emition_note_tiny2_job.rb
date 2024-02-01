class EmitionNoteTiny2Job < ActiveJob::Base
  def perform
    emission_tiny2
  end

  def emission_tiny2
    Attempt.where(kinds: :create_note_tiny2, status: :success).where.not(kinds: :emission_invoice_tiny2, status: :success).each do |att|
      attempt = Attempt.create(kinds: :emission_invoice_tiny2,
                               id_nota_tiny2: att.id_nota_tiny2,
                               id_nota_fiscal: att.id_nota_fiscal,
                               tiny_order_id: att.tiny_order_id)
      begin
        request = HTTParty.get(ENV.fetch('EMITIR_NOTA_FISCAL'),
                               query: { token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
                                        formato: 'string',
                                        id: att.id_nota_tiny2.to_s })
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end
    end
  end
end