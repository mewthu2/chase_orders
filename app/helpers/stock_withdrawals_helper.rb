module StockWithdrawalsHelper
  STATUS_PILLS = {
    'draft' => '', 'processing' => '', 'completed' => 'status-pill--active', 'partially_failed' => 'status-pill--inactive',
    'partially_completed' => '', 'reverted' => 'status-pill--inactive'
  }.freeze
  ITEM_STATUS = {
    'pending' => ['Pendente', ''], 'done' => ['Retirado', 'status-pill--active'], 'failed' => ['Falhou', 'status-pill--inactive'], 'reverted' => ['Revertido', '']
  }.freeze

  def withdrawal_status_pill(withdrawal)
    content_tag(:span, withdrawal.status_label, class: "status-pill #{STATUS_PILLS[withdrawal.status]}".strip)
  end

  def withdrawal_item_pill(item)
    label, css = ITEM_STATUS.fetch(item.status)
    content_tag(:span, label, class: "status-pill #{css}".strip)
  end
end
