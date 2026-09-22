# Remessa de uma transferência interna: os itens vindos de UMA loja de origem, com o próprio
# andamento (aberto → reservado → enviado → recebido, ou cancelado) e código de rastreio.
class InternalTransferShipment < ApplicationRecord
  STATUS_LABELS = {
    'aberto' => 'Aberta', 'reservado' => 'Reservada', 'enviado' => 'Enviada',
    'recebido' => 'Recebida', 'cancelado' => 'Cancelada'
  }.freeze

  belongs_to :internal_transfer, inverse_of: :shipments
  belongs_to :origin_location, class_name: 'Location'
  belongs_to :reserved_by, class_name: 'User', optional: true
  belongs_to :sent_by, class_name: 'User', optional: true
  belongs_to :received_by, class_name: 'User', optional: true
  belongs_to :cancelled_by, class_name: 'User', optional: true
  has_many :items, class_name: 'InternalTransferItem', dependent: :destroy, inverse_of: :internal_transfer_shipment, autosave: true

  enum :status, { aberto: 0, reservado: 1, enviado: 2, recebido: 3, cancelado: 4 }

  validate :origin_differs_from_destination

  def status_label
    STATUS_LABELS[status]
  end

  # Reservar: vale para abrir a remessa e também para tentar de novo os itens que falharam.
  def reservable?
    aberto? || (items.any?(&:failed?) && !recebido? && !cancelado?)
  end

  def sendable?
    reservado?
  end

  def receivable?
    enviado?
  end

  def cancellable?
    aberto? || reservado? || enviado?
  end

  # Já houve débito no Shopify (origem): cancelar precisa devolver o estoque.
  def returns_stock_on_cancel?
    reservado? || enviado?
  end

  private

  def origin_differs_from_destination
    return if origin_location.blank? || internal_transfer&.destination_location.blank?

    errors.add(:base, 'A loja de origem não pode ser a mesma loja de destino') if origin_location_id == internal_transfer.destination_location_id
  end
end
