module Whatsapp
  class Conversation < ApplicationRecord
    belongs_to :connection
    belongs_to :contact
    belongs_to :assignee, class_name: 'User', optional: true
    has_many :messages, dependent: :restrict_with_exception
    has_many :reads, dependent: :delete_all
    has_many :activities, dependent: :restrict_with_exception
    has_many :gaps, class_name: 'Whatsapp::AutomationGap', dependent: :delete_all
    STAGES = { 'pending' => 'Pendente', 'responding' => 'Respondendo', 'finished' => 'Finalizado' }.freeze
    validates :state, inclusion: { in: %w[open closed] }
    validates :stage, inclusion: { in: STAGES.keys }
    # "Finalizado" e "encerrada" são a mesma coisa; a situação acompanha o estado.
    before_save do
      if will_save_change_to_state?
        if state == 'closed'
          self.stage = 'finished'
          clear_agent_draft
        elsif stage == 'finished'
          self.stage = 'responding'
        end
      end
    end
    validate { errors.add(:contact, 'de outro número') if contact && contact.connection_id != connection_id }

    def self.visible_to(user) = where(connection_id: Connection.visible_to(user).select(:id))
    def unread_count(user)
      cursor = reads.find_by(user_id: user.id)&.last_message_id || 0
      messages.where(direction: 'incoming', historical: false).where('id > ?', cursor).count
    end

    def stage_label = STAGES[stage]

    def clear_agent_draft
      self.agent_draft = nil
      self.agent_draft_finish = false
      self.agent_draft_for_id = nil
    end

    # O cliente escreveu: conversa finalizada volta a ficar pendente, e o agente volta a valer.
    def customer_wrote!
      attrs = {}
      if state == 'closed' || stage == 'finished'
        attrs.merge!(state: 'open', stage: 'pending', agent_paused: false, needs_human: false, agent_note: nil)
      end
      assign_attributes(attrs)
      save! if changed?
    end

    # Alguém da equipe respondeu (pelo Honey ou pelo celular).
    def team_replied!(pause_agent: false)
      self.state = 'open'
      self.stage = 'responding'
      self.needs_human = false
      self.agent_note = nil if pause_agent
      self.agent_paused = true if pause_agent
      clear_agent_draft
      save! if changed?
    end

    def mark_read!(user, message_id)
      with_lock do
        cursor = reads.find_or_initialize_by(user: user)
        cursor.last_message_id = [cursor.last_message_id || 0, messages.where('id <= ?', message_id.to_i).maximum(:id) || 0].max
        cursor.save!
      end
    end
  end
end
