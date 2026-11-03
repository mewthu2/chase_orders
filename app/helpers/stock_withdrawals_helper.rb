module StockWithdrawalsHelper
  STATUS_PILLS = {
    'draft' => '', 'processing' => '', 'completed' => 'status-pill--active', 'partially_failed' => 'status-pill--inactive',
    'partially_completed' => '', 'reverted' => 'status-pill--inactive'
  }.freeze
  ITEM_STATUS = {
    'pending' => ['Pendente', ''], 'done' => ['Retirado', 'status-pill--active'], 'failed' => ['Falhou', 'status-pill--inactive'], 'reverted' => ['Revertido', '']
  }.freeze

  # Cor e explicação de cada situação (selo da lista, legenda e ajuda), como no protótipo.
  STATUS_TONES = {
    'draft' => ['gray', 'Salva, mas nada saiu do Shopify ainda. Dá para editar e excluir.'],
    'processing' => ['purple', 'As quantidades estão saindo do Shopify agora.'],
    'completed' => ['green', 'Tudo foi retirado do Shopify.'],
    'partially_failed' => ['red', 'Algumas linhas não saíram. Corrija e conclua de novo.'],
    'partially_completed' => ['yellow', 'Parte das linhas foi revertida.'],
    'reverted' => ['blue', 'Tudo voltou para o estoque.']
  }.freeze

  def withdrawal_status_pill(withdrawal)
    tone, tip = STATUS_TONES.fetch(withdrawal.status)
    hc_status(withdrawal.status_label, tone, tip: "#{withdrawal.status_label}: #{tip}")
  end

  def withdrawal_status_legend
    StockWithdrawal::STATUS_LABELS.map { |key, label| [label, STATUS_TONES[key][0], STATUS_TONES[key][1]] }
  end

  def withdrawal_item_pill(item)
    label, css = ITEM_STATUS.fetch(item.status)
    content_tag(:span, label, class: "status-pill #{css}".strip)
  end
end
