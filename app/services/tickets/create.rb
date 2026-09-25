module Tickets
  # Abre um chamado: copia os responsáveis da responsabilidade para o chamado (snapshot —
  # mudar a responsabilidade depois não mexe em chamados antigos), inclui os acompanhantes
  # escolhidos, calcula o prazo da primeira resposta e notifica todos.
  class Create
    def self.call(...) = new(...).call

    def initialize(requester:, attributes:, follower_ids: [])
      @requester = requester
      @attributes = attributes
      @follower_ids = Array(follower_ids).reject(&:blank?).map(&:to_i)
    end

    def call
      now = Time.current
      ticket = Ticket.new(@attributes)
      ticket.assign_attributes(requester: @requester, status: :awaiting_responsible, last_activity_at: now)
      ticket.due_at = now + ticket.response_time if ticket.ticket_responsability
      build_participants(ticket)
      return ticket unless ticket.valid? && responsible_present?(ticket)
      return ticket unless ticket.save

      TicketNotifier.ticket_opened(ticket)
      ticket
    end

    private

    # Sem ninguém do lado dos responsáveis o chamado ficaria parado sem que ninguém fosse avisado.
    # Exceção: admin que é o próprio responsável abre para si (e pode resolver qualquer chamado).
    def responsible_present?(ticket)
      return true if ticket.participants.any?(&:responsible?)
      return true if @requester.admin? && ticket.ticket_responsability&.users.to_a.include?(@requester)

      ticket.errors.add(:ticket_responsability, 'não tem nenhum responsável ativo além de você')
      false
    end

    def build_participants(ticket)
      ticket.participants.build(user: @requester, role: :requester)

      responsibles = ticket.ticket_responsability&.users.to_a.select(&:active?) - [@requester]
      responsibles.each { |user| ticket.participants.build(user: user, role: :responsible) }

      taken = [@requester.id] + responsibles.map(&:id)
      User.active.where(id: @follower_ids - taken).find_each do |user|
        ticket.participants.build(user: user, role: :follower)
      end
    end
  end
end
