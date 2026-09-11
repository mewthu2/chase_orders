class SendXmlCorreiosLogJob < ActiveJob::Base
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
    Attempt.find_by(id: marker_id)&.update(status: :error, error: e.message) if marker_id
    raise
  end

  def send_all_xml
    @send_xml = Attempt.where(kinds: :create_correios_order, status: :success)
                       .where.not(order_correios_id: nil)
                       .where(not_yet_sent_sql, kind: Attempt.kinds[:send_xml], status: Attempt.statuses[:success])
                       .distinct(:order_correios_id)

    @send_xml.each do |att|
      send_one_xml(att)
    end
  end

  def insist_on_send_xml
    @send_xml = Attempt.where(kinds: :create_correios_order, status: :success)
                       .where.not(order_correios_id: nil)
                       .where(not_yet_sent_sql, kind: Attempt.kinds[:get_tracking], status: Attempt.statuses[:success])
                       .distinct(:order_correios_id)

    @send_xml.each do |att|
      send_one_xml(att)
    end
  end

  def not_yet_sent_sql
    <<~SQL.squish
      NOT EXISTS (
        SELECT 1 FROM attempts later
        WHERE later.kinds = :kind
          AND later.status = :status
          AND later.order_correios_id = attempts.order_correios_id
      )
    SQL
  end

  def send_one_xml(att)
    begin
      attempt = Attempt.create(kinds: :send_xml)
      invoice = Tiny::Invoices.obtain_xml(att.id_nota_fiscal.to_s)
    rescue StandardError => e
      attempt.update(error: e, status: :error)
      return attempt
    end

    doc = Nokogiri::XML(invoice)

    doc.traverse do |node|
      node.content = att.order_correios_id.to_s if node.element? && node.name == 'xPed'
    end

    xml_nfe = doc.at('xml_nfe')

    if attempt.present? && xml_nfe.present?
      xml_nfe_content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + xml_nfe.inner_html

      attempt.update(
        xml_nota: xml_nfe_content.gsub("\n", ''),
        order_correios_id: att.order_correios_id,
        id_nota_fiscal: att.id_nota_fiscal,
        tiny_order_id: att.tiny_order_id
      )

      Correios::Invoices.send_xml_to_correios(attempt)
    else
      attempt.update(status: :error, error: "Nota vazia, pedido tiny: #{att.tiny_order_id}")
      Attempt.where(tiny_order_id: att.tiny_order_id, status: :success, kinds: :emission_invoice).destroy_all
    end

    attempt
  end
end
