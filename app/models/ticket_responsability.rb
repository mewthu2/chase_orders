# Área que recebe chamados: tem responsáveis fixos e o prazo (em horas corridas) que cada
# lado tem para responder a cada interação.
class TicketResponsability < ApplicationRecord
  # declarado antes das associações com dependent: :destroy — o restrict precisa rodar primeiro
  has_many :tickets, dependent: :restrict_with_error
  belongs_to :ticket_sector
  has_many :ticket_responsability_users, dependent: :destroy
  has_many :users, through: :ticket_responsability_users

  validates :name, presence: true, uniqueness: true
  validates :response_time_hours, numericality: { only_integer: true, greater_than: 0 }
  validate :must_have_an_active_responsible

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  def response_time_label
    hours = response_time_hours.to_i
    return "#{hours}h" if hours < 24 || (hours % 24).nonzero?

    days = hours / 24
    days == 1 ? '1 dia' : "#{days} dias"
  end

  private

  def must_have_an_active_responsible
    errors.add(:users, 'deve ter pelo menos um responsável ativo') unless users.any?(&:active?)
  end
end
