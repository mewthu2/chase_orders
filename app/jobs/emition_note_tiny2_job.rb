class EmitionNoteTiny2Job < ActiveJob::Base
  def perform
    emission_tiny2
  end

  private

  def emission_tiny2
    start_date = Time.new - 2.weeks

    ids_to_reject = Attempt.select(:tiny_order_id)
                           .where(kinds: :emission_invoice_tiny2, status: :success)
                           .where('created_at >= ?', start_date)

    Attempt.where(kinds: :create_note_tiny2, status: :success)
           .where.not(tiny_order_id: ids_to_reject).each do |att|
      attempt = Attempt.create(
        kinds: :emission_invoice_tiny2,
        id_nota_tiny2: att.id_nota_tiny2,
        id_nota_fiscal: att.id_nota_fiscal,
        tiny_order_id: att.tiny_order_id
      )

      begin
        request = HTTParty.get(ENV.fetch('EMITIR_NOTA_FISCAL'),
                               query: { token: ENV.fetch('TOKEN_TINY2_PRODUCTION'),
                                        formato: 'string',
                                        id: att.id_nota_tiny2 })
      rescue StandardError => e
        attempt.update(error: e.message, status: :error)
        next
      end

      if request.code == 200
        analyze_response(request.body, attempt)
      else
        attempt.update(status: :error, message: 'Erro ao comunicar com a API. Código HTTP não é 200.')
      end
    end
  end

  def analyze_response(response_body, attempt)
    parsed_response = Nokogiri::XML(response_body)

    status_processamento = parsed_response.at_xpath('//status_processamento')&.text
    status = parsed_response.at_xpath('//status')&.text
    erros = parsed_response.xpath('//erros/erro').map(&:text).join('; ')

    if status_processamento == '2' && status == 'Erro' && erros != 'Nota Fiscal não localizada, apenas notas pendentes ou rejeitadas podem ser enviadas'
      attempt.update(status: :error, message: "Erro na integração: #{erros}")
    else
      attempt.update(status: :success, message: erros)
    end
  rescue StandardError => e
    attempt.update(status: :error, message: "Erro ao analisar resposta: #{e.message}")
  end
end