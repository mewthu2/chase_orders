class Correios::Invoices
  def self.send_xml_to_correios(attempt)
    headers = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoArmazem' => ENV.fetch('CORREIOS_COD_ARMAZEM'),
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
    }
    p 'XISDE'
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
        attempt.update(status: :success, xml_sended: true, status_code: response.code) if response.body == attempt.xml_nota
      else
        attempt.update(status: :error, status_code: response.code, message: response.body)
      end
    end
  end
end