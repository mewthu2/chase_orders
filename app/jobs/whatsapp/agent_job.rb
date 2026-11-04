module Whatsapp
  # Roda o agente da automação ligada do número para a última mensagem do cliente.
  # É agendado alguns segundos depois da mensagem chegar: se o cliente mandar outra
  # nesse meio-tempo, só o job da mensagem mais nova age (as anteriores desistem).
  class AgentJob < ApplicationJob
    queue_as :whatsapp
    DELAY = 12.seconds
    THINKING = 'Pensando numa resposta…'.freeze

    def self.schedule(conversation, message)
      automation = Automation.active_for(conversation.connection_id)
      return unless automation
      conversation.expire_agent_pause!(automation) # modo conversa esgotado: o agente volta a ler
      return if conversation.agent_paused? # modo conversa: o agente nem lê
      # A cliente falou mais: a sugestão antiga sai e o agente reanalisa a conversa inteira.
      conversation.clear_agent_draft
      conversation.update!(agent_note: THINKING, needs_human: false)
      set(wait: DELAY).perform_later(conversation.id, message.id)
    end

    # force: pedido manual ("Pedir sugestão"), roda mesmo com o agente pausado e sempre como rascunho.
    def perform(conversation_id, message_id, force = false)
      conversation = Conversation.find_by(id: conversation_id) || return
      unless current_turn?(conversation, message_id, force)
        # Cliente escreveu de novo: o job da mensagem mais nova cuida. Outro motivo: para de "pensar".
        settle(conversation) if force || !newer_customer_message?(conversation, message_id)
        return
      end
      return settle(conversation) if conversation.agent_paused? && !force
      automation = Automation.active_for(conversation.connection_id)
      return settle(conversation) unless automation

      history = conversation.messages.where(historical: [false, true]).order(sent_at: :desc, id: :desc).limit(Agent::HISTORY).to_a.reverse
      rows = history.map { |m| { from: m.direction == 'incoming' ? 'cliente' : 'loja', text: m.body.presence || "[#{m.preview}]", at: m.sent_at } }
      decision = begin
        Agent.new(automation).decide(rows, contact_name: conversation.contact.display_name)
      rescue Agent::NotConfigured, Agent::Failure => e
        conversation.update_columns(agent_note: "Agente indisponível: #{e.message}".truncate(500), updated_at: Time.current)
        return
      end

      send_now = nil
      conversation.connection.with_lock do
        conversation.reload
        # Alguém respondeu ou o cliente escreveu de novo enquanto o agente pensava.
        unless current_turn?(conversation, message_id, force)
          settle(conversation) unless newer_customer_message?(conversation, message_id)
          return
        end
        return settle(conversation) if conversation.agent_paused? && !force
        apply(conversation, automation, decision, message_id, auto: automation.auto? && !force, force: force) { |m| send_now = m }
      end
      SendJob.perform_later(send_now.id) if send_now
    end

    private

    # A mensagem ainda é a última do cliente e ninguém respondeu depois dela.
    def settle(conversation)
      conversation.update_columns(agent_note: nil, updated_at: Time.current) if conversation.reload.agent_note == THINKING
      nil
    end

    def newer_customer_message?(conversation, message_id)
      conversation.messages.where(direction: 'incoming', historical: false).where('id > ?', message_id.to_i).exists?
    end

    # A resposta automática ignora o histórico importado; o pedido manual (force) não.
    def current_turn?(conversation, message_id, force = false)
      scope = force ? conversation.messages : conversation.messages.where(historical: false)
      last = scope.order(sent_at: :desc, id: :desc).first
      last && last.id == message_id.to_i && last.direction == 'incoming'
    end

    def apply(conversation, automation, decision, message_id, auto:, force: false)
      case decision.action
      when 'unsure'
        # Mesmo sem saber, deixa uma sugestão segura para a equipe (nunca é enviada sozinha).
        conversation.clear_agent_draft
        conversation.assign_attributes(agent_draft: decision.reply, agent_draft_for_id: message_id) if decision.reply.present?
        conversation.update!(needs_human: true, agent_note: "Não sei o que fazer neste caso: #{decision.question}".truncate(500))
        gap = automation.gaps.open.find_or_initialize_by(conversation: conversation, message_id: message_id)
        gap.update!(question: decision.question)
      when 'wait'
        note = ("O agente achou que não há nada para responder agora#{": #{decision.reason}" if decision.reason.present?}".truncate(500) if force)
        conversation.update!(agent_note: note) unless conversation.needs_human?
      else
        if !decision.reply? && decision.finish?
          conversation.update!(state: 'closed', agent_note: nil, needs_human: false) if auto
          conversation.update!(agent_draft: '', agent_draft_finish: true, agent_draft_for_id: message_id, agent_note: nil) unless auto
          return
        end
        if auto
          message = conversation.messages.find_by(client_nonce: nonce(conversation, message_id)) ||
            conversation.messages.create!(connection: conversation.connection, by_agent: true, client_nonce: nonce(conversation, message_id),
              body: decision.reply, direction: 'outgoing', state: 'queued', sent_at: Time.current)
          conversation.assign_attributes(last_message_at: message.sent_at, last_message_preview: message.preview.truncate(180),
            stage: 'responding', needs_human: false, agent_note: nil)
          conversation.clear_agent_draft
          conversation.save!
          conversation.update!(state: 'closed') if decision.finish?
          yield message if message.state == 'queued'
        else
          conversation.update!(agent_draft: decision.reply, agent_draft_finish: decision.finish?, agent_draft_for_id: message_id,
            needs_human: false, agent_note: nil)
        end
      end
    end

    def nonce(conversation, message_id) = "agent-#{conversation.id}-#{message_id}"
  end
end
