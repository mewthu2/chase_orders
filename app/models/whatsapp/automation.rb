module Whatsapp
  # Automação de conversa de um número: nome, modo (aprovar antes / responder sozinho),
  # instruções gerais e a lista de comandos "quando… faça…" que o agente segue.
  class Automation < ApplicationRecord
    MODES = { 'approve' => 'Eu aprovo cada resposta', 'auto' => 'Responde sozinho' }.freeze
    belongs_to :connection
    belongs_to :created_by, class_name: 'User', optional: true
    has_many :rules, -> { order(:position, :id) }, class_name: 'Whatsapp::AutomationRule', dependent: :destroy, inverse_of: :automation
    has_many :gaps, class_name: 'Whatsapp::AutomationGap', dependent: :destroy, inverse_of: :automation
    has_many :capabilities, class_name: 'Whatsapp::AutomationCapability', dependent: :destroy, inverse_of: :automation
    validates :name, presence: true, length: { maximum: 80 }
    validates :mode, inclusion: { in: MODES.keys }
    validates :instructions, length: { maximum: 8_000 }
    # Minutos sem a equipe escrever até o modo conversa desligar sozinho (0 = só desliga à mão).
    validates :conversation_mode_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_080 }
    # Só uma automação ligada por número: ligar uma desliga as outras.
    after_save :disable_siblings, if: -> { saved_change_to_enabled? && enabled? }

    def self.active_for(connection_id) = where(connection_id: connection_id, enabled: true).order(updated_at: :desc).first
    def auto? = mode == 'auto'
    def mode_label = MODES[mode]

    # Todas as funcionalidades do catálogo, salvas ou não (as não salvas estão desligadas).
    def capability_list
      saved = capabilities.index_by(&:key)
      AutomationCapability::CATALOG.keys.map { |key| saved[key] || AutomationCapability.new(automation: self, key: key) }
    end

    def capability(key) = capabilities.find_or_initialize_by(key: key)

    private
    def disable_siblings
      self.class.where(connection_id: connection_id, enabled: true).where.not(id: id).update_all(enabled: false, updated_at: Time.current)
    end
  end
end
