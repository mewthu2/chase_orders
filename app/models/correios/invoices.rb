class Correios::Invoices
  def self.send_xml_to_correios(invoice, attempt)
    headers = {
      'numeroCartaoPostagem' => ENV.fetch('CORREIOS_CARTAO_POSTAGEM'),
      'codigoArmazem' => ENV.fetch('CORREIOS_COD_ARMAZEM'),
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Authorization' => 'Basic YnJhc2lsY2hhc2U6dm84UXNoUGpKR2FGSHBCSGMwV2dOTDdiWjZKbEpBOEx5ZFRYRWtXTg==',
      'Cookie' => 'LBprdExt1=533331978.47873.0000; LBprdint3=1446707210.47873.0000'
    }

    body = { 'xml': invoice }

    begin
      request = HTTParty.post(ENV.fetch('CORREIOS_ENVIAR_XML'),
                              headers: headers,
                              body: body)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
      next
    end
  end
end