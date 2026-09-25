class TicketResponsabilityUser < ApplicationRecord
  belongs_to :ticket_responsability
  belongs_to :user

  validates :user_id, uniqueness: { scope: :ticket_responsability_id }
end
