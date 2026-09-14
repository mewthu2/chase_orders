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
    invoiced_ids = Attempt.where(kinds: :emission_invoice_tiny2, status: :success)
                          .pluck(:order_correios_id)

    @send_xml = Attempt
      .where(kinds: :create_correios_order_tiny2, status: :success)
      .where.not(order_correios_id: nil)
      .where(order_correios_id: invoiced_ids)
      .where(not_yet_sent_sql, kind: Attempt.kinds[:send_xml_tiny2], status: Attempt.statuses[:success])
      .distinct(:order_correios_id)

    @send_xml.each do |att|
      send_one_xml(att)
    end
  end

  def insist_on_send_xml
    invoiced_ids = Attempt.where(kinds: :emission_invoice_tiny2, status: :success)
                          .pluck(:order_correios_id)

    @send_xml = Attempt
      .where(
        kinds: :create_correios_order_tiny2,
        status: :success,
        is_transportadora: false
      )
      .where.not(order_correios_id: nil)
      .where(order_correios_id: invoiced_ids)
      .where(not_yet_sent_sql, kind: Attempt.kinds[:get_tracking_tiny2], status: Attempt.statuses[:success])
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
      return attempt
    end

    doc = Nokogiri::XML(invoice)

    order_number = att.order_correios_id.to_s

    products = doc.xpath('//*[local-name()="prod"]')

    if products.empty?
      attempt.update(
        status: :error,
        error: "Nenhuma tag prod encontrada na nota #{att.id_nota_fiscal}"
      )
      return attempt
    end

    products.each do |prod|
      xped = prod.at_xpath('./*[local-name()="xPed"]')

      if xped.present?
        xped.content = order_number
      else
        xped = Nokogiri::XML::Node.new('xPed', doc)
        xped.content = order_number

        ind_tot = prod.at_xpath('./*[local-name()="indTot"]')

        if ind_tot.present?
          ind_tot.add_next_sibling(xped)
        else
          prod.add_child(xped)
        end
      end
    end

    xml_nfe = doc.at_xpath('//*[local-name()="xml_nfe"]')

    if attempt.present? && xml_nfe.present?
      xml_nfe_content =
        %(<?xml version="1.0" encoding="UTF-8"?>\n) +
        xml_nfe.inner_html

      attempt.update!(
        xml_nota: xml_nfe_content.delete("\n"),
        order_correios_id: att.order_correios_id,
        id_nota_fiscal: att.id_nota_fiscal,
        tiny_order_id: att.tiny_order_id
      )

      Correios::Invoices.send_xml_to_correios(attempt)
    else
      attempt.update!(
        status: :error,
        error: "Nota vazia, pedido Tiny: #{att.tiny_order_id}"
      )

      Attempt.where(
        tiny_order_id: att.tiny_order_id,
        status: :success,
        kinds: :emission_invoice
      ).destroy_all
    end

    attempt
  end
end