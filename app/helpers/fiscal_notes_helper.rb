module FiscalNotesHelper
  STATUS_PILL_CLASSES = {
    'assinada' => 'status-pill--preparando', 'autorizada' => 'status-pill--active',
    'rejeitada' => 'status-pill--inactive', 'erro' => 'status-pill--inactive', 'cancelada' => 'status-pill--inactive'
  }.freeze
  SHOPIFY_ADMIN_ORDER_URL = 'https://admin.shopify.com/store/chasebrasil/orders/%s'.freeze

  def fiscal_note_status_pill(note)
    content_tag(:span, note.status_label, class: "status-pill #{STATUS_PILL_CLASSES[note.status]}".strip)
  end

  def fiscal_note_order_path(note)
    return format(SHOPIFY_ADMIN_ORDER_URL, note.order.shopify_order_id) if note.order&.shopify_order_id.present?
    return nil unless note.b2b_order

    note.b2b_order.stock_transfer? ? edit_stock_transfer_path(note.b2b_order) : edit_b2b_order_path(note.b2b_order)
  end

  def fiscal_note_order_label(note)
    return note.shopify_order_name if note.shopify_order_name.present?
    return "Transferência ##{note.internal_transfer_shipment.internal_transfer_id}" if note.internal_transfer_shipment

    note.b2b_order_id ? "##{note.b2b_order_id}" : '-'
  end

  # Para quem a nota foi: cliente do atacado, cliente do site ou a loja de destino da transferência.
  def fiscal_note_destination(note)
    if note.b2b_order then b2b_order_destination(note.b2b_order)
    elsif note.internal_transfer_shipment
      shipment = note.internal_transfer_shipment
      "#{shipment.origin_location.name} → #{shipment.internal_transfer.destination_location.name}"
    else note.order&.customer&.full_name
    end
  end

  def environment_switch(company)
    production = company.producao?
    button_to toggle_environment_company_path(company), method: :patch,
              class: "env-switch #{production ? 'env-switch--prod' : 'env-switch--hom'}",
              title: production ? 'Voltar para homologação' : 'Passar a emitir em produção',
              form: { data: { hc_confirm: (production ? { title: "Voltar #{company.legal_name} para homologação?", text: 'As próximas notas saem como teste, sem valor fiscal.', ok: 'Voltar para homologação' }
                                                    : { title: "Ligar produção para #{company.legal_name}?", text: 'As notas passam a ter valor fiscal.', ok: 'Ligar produção', danger: true }).to_json } } do
      safe_join([
        content_tag(:span, '', class: 'env-switch__track') { content_tag(:span, '', class: 'env-switch__knob') },
        content_tag(:span, production ? 'Produção' : 'Homologação', class: 'env-switch__label')
      ])
    end
  end
end
