module Whatsapp
  # Fim do prazo do modo conversa: se ninguém da equipe escreveu de novo, o agente volta a valer e, se a última
  # mensagem é da cliente e ficou sem resposta, já sugere (ou responde, no modo automático) na hora.
  # Cada mensagem da equipe agenda um destes; os antigos chegam antes do prazo novo e não fazem nada.
  class ResumeAgentJob < ApplicationJob
    queue_as :whatsapp

    def perform(conversation_id)
      conversation = Conversation.find_by(id: conversation_id) || return
      return if conversation.state == 'closed'

      automation = Automation.active_for(conversation.connection_id) || return
      return unless conversation.expire_agent_pause!(automation)

      last = conversation.messages.where(historical: false).order(sent_at: :desc, id: :desc).first
      return unless last&.direction == 'incoming'

      conversation.update!(agent_note: AgentJob::THINKING, needs_human: false)
      AgentJob.perform_later(conversation.id, last.id)
    end
  end
end
