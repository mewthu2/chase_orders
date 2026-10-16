# Transferência interna entre lojas (locations do Shopify). Tem uma loja de destino ("Minha
# loja é: ..."); os itens são agrupados por loja de origem em uma remessa (InternalTransferShipment)
# por origem, cada uma com o próprio andamento, código de rastreio e ajuste de estoque no Shopify.
# Nasce aguardando aprovação de um dos aprovadores (InternalTransferApprover) ou de um admin: só depois de
# aprovada as remessas podem ser reservadas. O recebimento não passa por aprovação.
class InternalTransfer < ApplicationRecord
  class NotPending < StandardError; end

  STATUS_LABELS = {
    'aguardando_aprovacao' => 'Aguardando aprovação', 'reprovada' => 'Reprovada',
    'aberto' => 'Aberta', 'em_andamento' => 'Em andamento', 'concluida' => 'Concluída', 'cancelada' => 'Cancelada'
  }.freeze

  belongs_to :destination_location, class_name: 'Location'
  belongs_to :requested_by, class_name: 'User'
  belongs_to :reviewed_by, class_name: 'User', optional: true
  has_many :shipments, class_name: 'InternalTransferShipment', dependent: :destroy, inverse_of: :internal_transfer, autosave: true
  has_many :events, class_name: 'InternalTransferEvent', dependent: :destroy

  validate :must_have_items
  validate :shipments_are_valid

  enum :approval_status, { pendente: 0, aprovada: 1, reprovada: 2 }, prefix: :approval

  scope :recent, -> { order(created_at: :desc) }

  # Status geral (overall_status) em SQL, para filtrar a lista sem carregar as remessas.
  def self.with_overall_status(status)
    shipments = InternalTransferShipment
    ids_with = ->(statuses) { shipments.where(status: statuses).select(:internal_transfer_id) }
    ids_without = ->(statuses) { shipments.where.not(status: statuses).select(:internal_transfer_id) }
    active = %w[aberto reservado enviado]

    case status.to_s
    when 'aguardando_aprovacao' then approval_pendente
    when 'reprovada' then approval_reprovada
    when 'aberto' then approval_aprovada.where.not(id: ids_without.call('aberto'))
    when 'cancelada' then approval_aprovada.where(id: ids_with.call('cancelado')).where.not(id: ids_without.call('cancelado'))
    when 'concluida' then approval_aprovada.where(id: ids_with.call('recebido')).where.not(id: ids_with.call(active))
    when 'em_andamento' then approval_aprovada.where(id: ids_with.call(active)).where(id: ids_without.call('aberto'))
    else all
    end
  end

  # Busca pelo número, observação, solicitante, código de rastreio ou produto (SKU/nome).
  def self.search(query)
    text = query.to_s.strip
    return all if text.empty?

    like = "%#{sanitize_sql_like(text)}%"
    by_product = InternalTransferShipment.joins(items: :product)
                                         .where('products.sku LIKE :q OR products.shopify_product_name LIKE :q', q: like)
                                         .select(:internal_transfer_id)
    by_tracking = InternalTransferShipment.where('tracking_code LIKE ?', like).select(:internal_transfer_id)

    found = where('internal_transfers.notes LIKE ?', like)
            .or(where(requested_by_id: User.where('name LIKE ?', like).select(:id)))
            .or(where(id: by_product)).or(where(id: by_tracking))
    number = text.delete_prefix('#')
    number.match?(/\A\d+\z/) ? found.or(where(id: number.to_i)) : found
  end

  def self.with_origin(location_id)
    where(id: InternalTransferShipment.where(origin_location_id: location_id).select(:internal_transfer_id))
  end

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
    return 'aguardando_aprovacao' if approval_pendente?
    return 'reprovada' if approval_reprovada?

    statuses = shipments.map(&:status)
    return 'aberto' if statuses.all? { |status| status == 'aberto' }
    return 'cancelada' if statuses.all? { |status| status == 'cancelado' }
    return 'concluida' if statuses.all? { |status| %w[recebido cancelado].include?(status) } && statuses.include?('recebido')

    'em_andamento'
  end

  def overall_status_label
    STATUS_LABELS[overall_status]
  end

  # Só dá para editar ou excluir enquanto nenhuma remessa saiu do estado inicial (e não foi reprovada).
  def editable?
    !approval_reprovada? && shipments.all?(&:aberto?)
  end

  def deletable?
    editable?
  end

  # Aprova: libera as remessas para serem reservadas na origem.
  def approve!(user)
    with_lock do
      raise NotPending, 'Esta transferência não está aguardando aprovação.' unless approval_pendente?

      update!(approval_status: :aprovada, reviewed_by: user, reviewed_at: Time.current)
    end
    events.create!(user: user, action: 'approved', message: 'Transferência aprovada. As lojas de origem já podem reservar os itens.')
  end

  # Reprova: cancela todas as remessas. Como nada foi reservado antes da aprovação, não há
  # estoque a devolver no Shopify.
  def reject!(user, reason: nil)
    now = Time.current
    with_lock do
      raise NotPending, 'Esta transferência não está aguardando aprovação.' unless approval_pendente?

      update!(approval_status: :reprovada, reviewed_by: user, reviewed_at: now, rejection_reason: reason.presence)
      shipments.each do |shipment|
        shipment.items.each { |item| item.update!(status: :cancelled, cancelled_at: now) }
        shipment.update!(status: :cancelado, cancelled_at: now, cancelled_by: user)
      end
    end
    events.create!(user: user, action: 'rejected', message: "Transferência reprovada#{": #{reason}" if reason.present?}.")
  end

  # A location de `user` participa como origem (com algo a reservar/enviar) ou como destino
  # (com algo a receber), ou `user` pode aprovar (aprovador ou admin) e há aprovação pendente?
  # Usado para destacar "Aguardando sua ação" na lista.
  def my_action_needed?(user, approver_ids: InternalTransferApprover.user_ids)
    return user.admin? || approver_ids.include?(user.id) if approval_pendente?

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
