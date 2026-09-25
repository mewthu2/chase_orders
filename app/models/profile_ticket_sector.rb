class ProfileTicketSector < ApplicationRecord
  belongs_to :profile
  belongs_to :ticket_sector

  validates :ticket_sector_id, uniqueness: { scope: :profile_id }
end
