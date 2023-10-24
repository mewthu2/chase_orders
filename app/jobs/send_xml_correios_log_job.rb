class SendXmlCorreiosLogJob < ActiveJob::Base
  def perform(param)
    case param
    when 'all'
      send_all_xml
    when 'one'
      send_one_xml(att)
    end
  end

  def send_all_xml
    Attempt.where(kinds: :create_correios_order, status: 2).each do |att|
      next if Attempt.find_by(kinds: :send_xml, status: 2, order_correios_id: att.order_correios_id).present?
      send_one_xml(att)
    end
  end

  def send_one_xml(att)
    begin
      attempt = Attempt.create(kinds: :send_xml)
      invoice = Tiny::Invoices.obtain_xml(att.id_nota_fiscal.to_s)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end
    doc = Nokogiri::XML(invoice)

    doc.traverse do |node|
      node.content = att.order_correios_id.to_s if node.element? && node.name == 'xPed'
    end

    attempt.update(xml_nota: doc.to_xml.gsub("\n", ''),
                   order_correios_id: att.order_correios_id,
                   id_nota_fiscal: att.id_nota_fiscal,
                   tiny_order_id: att.tiny_order_id)

    if attempt.present?
      Correios::Invoices.send_xml_to_correios(attempt)
    else
      attempt.update(status: :error, error: 'Nota vazia')
    end
  end
end