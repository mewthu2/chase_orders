class TicketParticipant < ApplicationRecord
  ROLE_LABELS = { 'requester' => 'Solicitante', 'responsible' => 'Responsável', 'follower' => 'Acompanhante' }.freeze

  enum :role, { requester: 0, responsible: 1, follower: 2 }

  belongs_to :ticket
  belongs_to :user

  validates :user_id, uniqueness: { scope: :ticket_id }

  def role_label = ROLE_LABELS[role]
end
