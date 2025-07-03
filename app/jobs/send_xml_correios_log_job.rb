class SendXmlCorreiosLogJob < ActiveJob::Base
  def perform(param, att)
    case param
    when 'all'
      send_all_xml
    when 'one'
      send_one_xml(att)
    end
  end

  def send_all_xml
    @send_xml = Attempt.where(kinds: :create_correios_order, status: 2)
                       .distinct(:order_correios_id)
                       .where.not(order_correios_id: Attempt.where(kinds: :send_xml, status: 2).pluck(:order_correios_id))

    @send_xml.each do |att|
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

    if attempt.present? && doc.at('xml_nfe').present?
      xml_nfe_content = doc.at('xml_nfe').inner_html

      attempt.update(xml_nota: xml_nfe_content.gsub("\n", ''),
                     order_correios_id: att.order_correios_id,
                     id_nota_fiscal: att.id_nota_fiscal,
                     tiny_order_id: att.tiny_order_id)

      Correios::Invoices.send_xml_to_correios(attempt)
    else
      attempt.update(status: :error, error: "Nota vazia, pedido tiny: #{att.tiny_order_id}")
      Attempt.where(tiny_order_id: att.tiny_order_id, status: :success, kinds: :emission_invoice).destroy_all
    end
  end
end
