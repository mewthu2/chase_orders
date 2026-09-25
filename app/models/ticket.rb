# Chamado aberto por um usuário para uma responsabilidade. O prazo (due_at) vale para quem
# está com a vez e é recalculado quando alguém muda o status — ver Tickets::AddMessage.
class Ticket < ApplicationRecord
  include HasTicketAttachments

  OPEN_STATUSES = %w[awaiting_responsible awaiting_requester in_progress].freeze
  STATUS_LABELS = {
    'awaiting_responsible' => 'Aguardando responsável',
    'awaiting_requester' => 'Aguardando solicitante',
    'in_progress' => 'Em andamento',
    'resolved' => 'Resolvido',
    'closed' => 'Fechado'
  }.freeze
  DUE_SOON_WINDOW = 2.hours

  enum :status, { awaiting_responsible: 0, awaiting_requester: 1, in_progress: 2, resolved: 3, closed: 4 }

  belongs_to :ticket_responsability
  belongs_to :requester, class_name: 'User'
  has_many :participants, class_name: 'TicketParticipant', dependent: :destroy
  has_many :users, through: :participants
  has_many :messages, -> { order(:created_at, :id) }, class_name: 'TicketMessage', dependent: :destroy

  validates :title, presence: true, length: { maximum: 150 }
  validates :description, presence: true
  validate :responsability_must_be_active, on: :create

  scope :open_tickets, -> { where(status: OPEN_STATUSES) }
  scope :overdue, -> { open_tickets.where('tickets.due_at < ?', Time.current) }
  scope :pending_overdue_notification, -> { overdue.where(overdue_notified_at: nil) }
  scope :recent_activity, -> { order(Arel.sql('COALESCE(tickets.last_activity_at, tickets.created_at) DESC'), id: :desc) }
  scope :involving, ->(user) { where(id: TicketParticipant.where(user_id: user.id).select(:ticket_id)) }
  scope :in_sectors, ->(sector_ids) { where(ticket_responsability_id: TicketResponsability.where(ticket_sector_id: sector_ids).select(:id)) }
  # Participa do chamado ou enxerga o setor dele (admin vê tudo).
  scope :visible_to, lambda { |user|
    next all if user.admin?

    involving(user).or(in_sectors(user.visible_ticket_sector_ids))
  }

  def self.status_label(status) = STATUS_LABELS[status.to_s]

  def status_label = STATUS_LABELS[status]
  def open? = OPEN_STATUSES.include?(status)
  def overdue? = open? && due_at.present? && due_at < Time.current
  def due_soon? = open? && due_at.present? && !overdue? && due_at < DUE_SOON_WINDOW.from_now
  def response_time = ticket_responsability.response_time_hours.hours

  def participant_for(user) = participants.find { |participant| participant.user_id == user.id }
  def role_of(user) = participant_for(user)&.role
  def participant?(user) = participant_for(user).present?
  def visible_to?(user) = user.admin? || participant?(user) || user.visible_ticket_sector_ids.include?(sector&.id)
  def sector = ticket_responsability&.ticket_sector
  def requester?(user) = requester_id == user.id

  def responsibles = participants.select(&:responsible?).map(&:user)
  def followers = participants.select(&:follower?).map(&:user)

  # Quem precisa responder agora.
  def waiting_on_users
    return [] unless open?

    awaiting_requester? ? [requester] : responsibles
  end

  def waiting_on?(user) = waiting_on_users.include?(user)

  def waiting_on_label
    return unless open?

    awaiting_requester? ? 'Solicitante' : 'Responsáveis'
  end

  def can_resolve?(user) = user.admin? || %w[responsible follower].include?(role_of(user))
  def can_close_or_reopen?(user) = user.admin? || requester?(user)

  # Status que o usuário pode escolher ao interagir.
  def allowed_statuses_for(user)
    if open?
      statuses = OPEN_STATUSES - [status]
      statuses << 'resolved' if can_resolve?(user)
      statuses << 'closed' if can_close_or_reopen?(user)
      statuses
    elsif can_close_or_reopen?(user)
      resolved? ? OPEN_STATUSES + ['closed'] : OPEN_STATUSES.dup
    else
      []
    end
  end

  private

  def responsability_must_be_active
    return if ticket_responsability.nil? || ticket_responsability.active?

    errors.add(:ticket_responsability, 'está inativa')
  end
end
