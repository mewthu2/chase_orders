class EmitionNoteTiny2Job < ActiveJob::Base
  def perform
    emission_tiny2
  end

  def emission_tiny2
    ids_to_reject = Attempt.where(kinds: :emission_invoice_tiny2, status: :success).pluck(:tiny_order_id)
    Attempt.where(kinds: :create_note_tiny2, status: :success).where.not(tiny_order_id: ids_to_reject).each do |att|
      attempt = Attempt.create(kinds: :emission_invoice_tiny2,
                               id_nota_tiny2: att.id_nota_tiny2,
                               id_nota_fiscal: att.id_nota_fiscal,
                               tiny_order_id: att.tiny_order_id)
      begin
        request = HTTParty.get(ENV.fetch('EMITIR_NOTA_FISCAL'),
                               query: { token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
                                        formato: 'string',
                                        id: att.id_nota_tiny2 })
      rescue StandardError => e
        attempt.update(error: e, status: :error)
      end
      if request.code == 200
        attempt.update(status: :success)
      else
        attempt.update(status: :error, message: 'Algo ocorreu de errado na integração dos dados')
      end
    end
  end
end
