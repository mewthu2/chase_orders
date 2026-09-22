# Linha do tempo de uma transferência interna: quem fez o quê, em qual remessa, e quando.
class InternalTransferEvent < ApplicationRecord
  ACTION_LABELS = {
    'created' => 'Transferência criada', 'reserved' => 'Itens reservados', 'reservation_failed' => 'Falha ao reservar',
    'shipped' => 'Marcada como enviada', 'received' => 'Recebida', 'cancelled' => 'Cancelada'
  }.freeze

  belongs_to :internal_transfer
  belongs_to :internal_transfer_shipment, optional: true
  belongs_to :user, optional: true

  scope :recent, -> { order(created_at: :desc) }

  def action_label
    ACTION_LABELS.fetch(action, action)
  end
end
