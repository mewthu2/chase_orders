class SendXmlCorreiosLogJob2 < ActiveJob::Base
  def perform(param, att, marker_id = nil)
    case param
    when 'all'
      send_all_xml
      insist_on_send_xml
    when 'one'
      send_one_xml(att)
    end

    Attempt.find_by(id: marker_id)&.update(status: :success) if marker_id
  rescue StandardError => e
    Attempt.find_by(id: marker_id)&.update(
      status: :error,
      error: e.message
    ) if marker_id

    raise
  end

  def send_all_xml
    @send_xml = Attempt
      .where(kinds: :create_correios_order_tiny2, status: 2)
      .distinct(:order_correios_id)
      .where.not(
        order_correios_id: Attempt
          .where(kinds: :send_xml_tiny2, status: 2)
          .pluck(:order_correios_id)
      )

    @send_xml.each do |att|
      send_one_xml(att)
    end
  end

  def insist_on_send_xml
    @send_xml = Attempt
      .where(
        kinds: :create_correios_order_tiny2,
        status: 2,
        is_transportadora: false
      )
      .distinct(:order_correios_id)
      .where.not(
        order_correios_id: Attempt
          .where(kinds: :get_tracking_tiny2, status: 2)
          .pluck(:order_correios_id)
      )

    @send_xml.each do |att|
      send_one_xml(att)
    end
  end

  def send_one_xml(att)
    begin
      attempt = Attempt.create(
        kinds: :send_xml_tiny2,
        is_transportadora: att.is_transportadora,
        tiny_order_id: att.tiny_order_id,
        order_correios_id: att.order_correios_id
      )

      invoice = Tiny::Invoices.obtain_xml(
        att.id_nota_fiscal.to_s,
        ENV.fetch('TOKEN_TINY2_PRODUCTION')
      )
    rescue StandardError => e
      attempt&.update(
        error: e.message,
        status: :error
      )
      return
    end

    doc = Nokogiri::XML(invoice)

    doc.traverse do |node|
      if node.element? && node.name == 'xPed'
        node.content = att.order_correios_id.to_s
      end
    end

    xml_nfe = doc.at_xpath('//*[local-name()="xml_nfe"]')

    if xml_nfe.present?
      xml_nfe_content =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n#{xml_nfe.inner_html}"

      attempt.update(
        xml_nota: xml_nfe_content.gsub("\n", ''),
        order_correios_id: att.order_correios_id,
        id_nota_fiscal: att.id_nota_fiscal,
        tiny_order_id: att.tiny_order_id
      )

      Correios::Invoices.send_xml_to_correios(attempt)
    else
      attempt.update(
        status: :error,
        error: "Nota vazia, pedido tiny: #{att.tiny_order_id}"
      )

      Attempt.where(
        tiny_order_id: att.tiny_order_id,
        status: :success,
        kinds: :emission_invoice_tiny2
      ).destroy_all
    end
  end
end