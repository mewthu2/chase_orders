class SendXmlCorreiosLogJob < ActiveJob::Base
  def perform(param)
    case param
    when 'all'
      send_all_xml
    when 'one'
      send_one_xml(params)
    end
  end

  def send_all
    Attempt.where(kinds: :create_correios_order, xml_sended: false).each do |att|
      send_one_xml(att)
    end
  end

  def send_one_xml(att)
    attempt = Attempt.create(kinds: :send_xml)

    begin
      invoice = Tiny::Invoices.obtain_xml(invoice_id)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
    end

    doc = Nokogiri::XML(invoice)

    doc.traverse do |node|
      if node.element?
        if node.name == 'xPed'
          node.content = "801908784"
        end
      end
    end

    attempt.update(xml_nota: doc.to_xml)

    send_xml_to_correios(attempt)
  end
end