module Whatsapp
  # Um comando ensinado ao agente: "quando <trigger>" → "faça/responda <response>".
  class AutomationRule < ApplicationRecord
    belongs_to :automation, class_name: 'Whatsapp::Automation', inverse_of: :rules
    validates :trigger, presence: true, length: { maximum: 1_000 }
    validates :response, presence: true, length: { maximum: 4_000 }
    before_create { self.position = (automation.rules.maximum(:position) || 0) + 1 if position.to_i.zero? }
  end
end
