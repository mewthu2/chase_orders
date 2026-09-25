module Tickets
  # Registra uma interação e aplica a regra de status/prazo:
  # - sem status escolhido, é só um comentário: status e prazo continuam como estão;
  # - status escolhido precisa estar em ticket.allowed_statuses_for(author);
  # - "resolved" exige o texto da solução, que fica guardado no chamado.
  # Admin que não participa e interage entra como acompanhante.
  class AddMessage
    def self.call(...) = new(...).call

    def initialize(ticket:, author:, body: nil, status: nil, attachments: [])
      @ticket = ticket
      @author = author
      @body = body.to_s.strip.presence
      @status = status.presence
      @attachments = Array(attachments).reject(&:blank?)
    end

    def call
      @message = TicketMessage.new(ticket: @ticket, user: @author, kind: :comment, body: @body, attachments: @attachments)
      @message.status_to = Ticket.statuses[@status] if @status
      return @message unless permitted? && @message.valid?

      @message.status_from = Ticket.statuses[@ticket.status] if @status
      apply_transition(Time.current)

      Ticket.transaction do
        ensure_participant
        @message.save!
        @ticket.save!
      end
      TicketNotifier.message_created(@message)
      @message
    end

    private

    def permitted?
      unless @ticket.visible_to?(@author)
        @message.errors.add(:base, 'Você não participa deste chamado')
        return false
      end
      return true unless @status

      unless @ticket.allowed_statuses_for(@author).include?(@status)
        @message.errors.add(:base, 'Você não pode mudar o chamado para esse status')
        return false
      end
      if @status == 'resolved' && @body.blank?
        @message.errors.add(:base, 'Descreva a solução para marcar como resolvido')
        return false
      end
      true
    end

    def apply_transition(now)
      @ticket.last_activity_at = now
      return unless @status

      @ticket.overdue_notified_at = nil
      @ticket.status = @status
      case @status
      when 'resolved'
        @ticket.assign_attributes(solution: @body, resolved_at: now, closed_at: nil, due_at: nil)
      when 'closed'
        @ticket.assign_attributes(closed_at: now, due_at: nil)
      else
        @ticket.assign_attributes(resolved_at: nil, closed_at: nil, due_at: now + @ticket.response_time)
      end
    end

    def ensure_participant
      return if @ticket.participant?(@author)

      @ticket.participants.create!(user: @author, role: :follower)
    end
  end
end
