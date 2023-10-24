class Correios::Invoices
  def self.send_xml_to_correios(attempt)
    headers = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoArmazem' => ENV.fetch('CORREIOS_COD_ARMAZEM'),
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
    }

    body = { 'xml': attempt.xml_nota }

    begin
      response = HTTParty.post(ENV.fetch('CORREIOS_ENVIAR_XML'),
                               headers: headers,
                               body: body)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    if response.present?
      case response.code
      when 200
        attempt.update(status: :success, xml_sended: true, status_code: response.code) if response.body == attempt.xml_nota
      when 400
        if response.body.include?('faturado')
          attempt.update(status: :success, status_code: response.code, message: response.body)
        else
          attempt.update(status: :error, status_code: response.code, message: response.body)
        end
      end
    else
      attempt.update(status: :error, message: 'Requisição vazia')
    end
  end
end