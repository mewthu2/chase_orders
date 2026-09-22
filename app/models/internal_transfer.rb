# Transferência interna entre lojas (locations do Shopify). Tem uma loja de destino ("Minha
# loja é: ..."); os itens são agrupados por loja de origem em uma remessa (InternalTransferShipment)
# por origem, cada uma com o próprio andamento, código de rastreio e ajuste de estoque no Shopify.
class InternalTransfer < ApplicationRecord
  STATUS_LABELS = { 'aberto' => 'Aberta', 'em_andamento' => 'Em andamento', 'concluida' => 'Concluída', 'cancelada' => 'Cancelada' }.freeze

  belongs_to :destination_location, class_name: 'Location'
  belongs_to :requested_by, class_name: 'User'
  has_many :shipments, class_name: 'InternalTransferShipment', dependent: :destroy, inverse_of: :internal_transfer, autosave: true
  has_many :events, class_name: 'InternalTransferEvent', dependent: :destroy

  validate :must_have_items
  validate :shipments_are_valid

  scope :recent, -> { order(created_at: :desc) }

  # Pedidos em que a location (por slug) participa, como origem ou como destino.
  def self.involving_location_slug(slug)
    location = Location.find_by(slug: slug)
    return none unless location

    origin_ids = InternalTransferShipment.where(origin_location_id: location.id).select(:internal_transfer_id)
    where(destination_location_id: location.id).or(where(id: origin_ids))
  end

  def total_quantity
    shipments.sum { |shipment| shipment.items.sum(&:quantity) }
  end

  def overall_status
    statuses = shipments.map(&:status)
    return 'aberto' if statuses.all? { |status| status == 'aberto' }
    return 'cancelada' if statuses.all? { |status| status == 'cancelado' }
    return 'concluida' if statuses.all? { |status| %w[recebido cancelado].include?(status) } && statuses.include?('recebido')

    'em_andamento'
  end

  def overall_status_label
    STATUS_LABELS[overall_status]
  end

  # Só dá para editar ou excluir enquanto nenhuma remessa saiu do estado inicial.
  def editable?
    shipments.all?(&:aberto?)
  end

  def deletable?
    editable?
  end

  # A location de `user` participa como origem (com algo a reservar/enviar) ou como destino
  # (com algo a receber)? Usado para destacar "Aguardando sua ação" na lista.
  def my_action_needed?(user)
    shipments.any? do |shipment|
      (shipment.reservable? && user_can?(user, shipment.origin_location)) ||
        (shipment.sendable? && user_can?(user, shipment.origin_location)) ||
        (shipment.receivable? && user_can?(user, destination_location))
    end
  end

  private

  def user_can?(user, location)
    user.admin? || user.can_access_location?(location.slug)
  end

  def must_have_items
    errors.add(:base, 'A transferência precisa ter pelo menos um item') if shipments.flat_map(&:items).reject(&:marked_for_destruction?).empty?
  end

  # Repassa os erros dos itens/remessas em vez do genérico "Shipments não é válido".
  def shipments_are_valid
    shipments.each do |shipment|
      next if shipment.marked_for_destruction? || shipment.valid?

      shipment.errors.full_messages.each { |message| errors.add(:base, message) }
    end
  end
end
