module InternalTransfersHelper
  TRANSFER_STATUS_PILLS = { 'aberto' => '', 'em_andamento' => '', 'concluida' => 'status-pill--active', 'cancelada' => 'status-pill--inactive' }.freeze
  SHIPMENT_STATUS_PILLS = {
    'aberto' => '', 'reservado' => '', 'enviado' => '', 'recebido' => 'status-pill--active', 'cancelado' => 'status-pill--inactive'
  }.freeze
  ITEM_STATUS_LABELS = {
    'pending' => ['Pendente', ''], 'reserved' => ['Reservado', ''], 'received' => ['Recebido', 'status-pill--active'],
    'failed' => ['Falhou', 'status-pill--inactive'], 'cancelled' => ['Cancelado', 'status-pill--inactive']
  }.freeze

  def transfer_status_pill(transfer)
    content_tag(:span, transfer.overall_status_label, class: "status-pill #{TRANSFER_STATUS_PILLS[transfer.overall_status]}".strip)
  end

  def shipment_status_pill(shipment)
    content_tag(:span, shipment.status_label, class: "status-pill #{SHIPMENT_STATUS_PILLS[shipment.status]}".strip)
  end

  def status_pill_for_item(item)
    label, css = ITEM_STATUS_LABELS.fetch(item.status)
    content_tag(:span, label, class: "status-pill #{css}".strip)
  end

  def action_needed_badge(transfer)
    return unless transfer.my_action_needed?(current_user)

    content_tag(:span, 'Aguardando sua ação', class: 'badge bg-warning text-dark action-needed-badge')
  end

  # Quem gerencia a loja de origem (ou admin) pode reservar/enviar aquela remessa.
  def can_manage_origin?(shipment)
    current_user.admin? || current_user.can_access_location?(shipment.origin_location.slug)
  end

  # Quem gerencia a loja de destino (ou admin) pode receber.
  def can_manage_destination?(transfer)
    current_user.admin? || current_user.can_access_location?(transfer.destination_location.slug)
  end

  # Cancelar: quem gerencia a origem (ou admin) sempre pode; quem pediu só enquanto está aberta.
  def can_cancel_shipment?(shipment)
    can_manage_origin?(shipment) || (shipment.aberto? && shipment.internal_transfer.requested_by_id == current_user.id)
  end
end
