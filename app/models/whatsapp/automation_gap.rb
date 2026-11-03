module Whatsapp
  # Pergunta que o agente não soube responder ("não sei o que fazer neste caso").
  # Vira um comando novo quando alguém ensina a resposta.
  class AutomationGap < ApplicationRecord
    STATES = %w[open taught dismissed].freeze
    belongs_to :automation, class_name: 'Whatsapp::Automation', inverse_of: :gaps
    belongs_to :conversation
    belongs_to :rule, class_name: 'Whatsapp::AutomationRule', optional: true
    validates :question, presence: true, length: { maximum: 1_000 }
    validates :state, inclusion: { in: STATES }
    scope :open, -> { where(state: 'open') }
  end
end
