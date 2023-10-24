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
      if response.code == 200
        attempt.update(status: response.body == attempt.xml_nota ? :success : :error, xml_sended: true, status_code: response.code)
      elsif response.body.include?('faturado')
        attempt.update(status: :success, status_code: response.code, message: response.body)
      else
        attempt.update(status: :error, status_code: response.code, message: response.body)
      end
    else
      attempt.update(status: :error, message: 'Requisição vazia')
    end
  end
end