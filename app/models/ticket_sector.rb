# Setor que agrupa responsabilidades de chamados. Os perfis liberam quais setores seus usuários
# enxergam (admin vê todos) — ver User#visible_ticket_sector_ids.
class TicketSector < ApplicationRecord
  has_many :ticket_responsabilities, dependent: :restrict_with_error
  has_many :profile_ticket_sectors, dependent: :destroy
  has_many :profiles, through: :profile_ticket_sectors

  validates :name, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }
end
