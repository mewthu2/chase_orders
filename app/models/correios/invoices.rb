class Correios::Invoices
  def self.send_xml_to_correios(attempt)
    headers = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoArmazem' => ENV.fetch('CORREIOS_COD_ARMAZEM'),
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Authorization' => "Basic #{Base64.strict_encode64(ENV.fetch('TOKEN_LOG_PRODUCTION'))}"
    }

    body = { xml: attempt.xml_nota }

    begin
      response = HTTParty.post(ENV.fetch('CORREIOS_ENVIAR_XML'),
                               headers:,
                               body:)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if response&.body.present?
      case response.code
      when 200
        attempt.update(status: :success, xml_sended: true, status_code: response.code) if response.body == attempt.xml_nota
      when 400
        begin
          tracking = Correios::Orders.get_tracking(attempt.order_correios_id)
        rescue StandardError => e
          attempt.update(error: e, message: 'Erro ao solicitar o rastreio', status: :error)
        end
        if response.body.include?('faturado') && racking.present? && tracking['rastreio'].present? && tracking['rastreio'][0].present?
          attempt.update(status: :success, status_code: response.code, message: response.body, xml_sended: true, tracking: tracking['rastreio'][0]['codigoObjeto'])
        else
          attempt.update(status: :error, status_code: response.code, message: response.body)
        end
      end
    else
      attempt.update(status: :error, message: 'Requisição vazia')
    end
  end
end