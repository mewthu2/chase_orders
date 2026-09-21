module FiscalNotesHelper
  STATUS_PILL_CLASSES = {
    'assinada' => 'status-pill--active', 'autorizada' => 'status-pill--active',
    'rejeitada' => 'status-pill--inactive', 'erro' => 'status-pill--inactive', 'cancelada' => 'status-pill--inactive'
  }.freeze

  def fiscal_note_status_pill(note)
    content_tag(:span, note.status_label, class: "status-pill #{STATUS_PILL_CLASSES[note.status]}".strip)
  end

  def fiscal_note_order_path(note)
    return nil unless note.b2b_order

    note.b2b_order.stock_transfer? ? edit_stock_transfer_path(note.b2b_order) : edit_b2b_order_path(note.b2b_order)
  end
end
