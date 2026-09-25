module Tickets
  # Chama outra pessoa para acompanhar o chamado: vira participante (follower), fica
  # registrado na timeline e só ela recebe e-mail.
  class AddFollower
    Result = Data.define(:success, :error) do
      def success? = success
    end

    def self.call(...) = new(...).call

    def initialize(ticket:, user:, added_by:)
      @ticket = ticket
      @user = user
      @added_by = added_by
    end

    def call
      return failure('Você não participa deste chamado') unless @ticket.visible_to?(@added_by)
      return failure('Usuário inválido ou inativo') unless @user&.active?
      return failure("#{@user.name} já participa deste chamado") if @ticket.participant?(@user)

      Ticket.transaction do
        @ticket.participants.create!(user: @user, role: :follower)
        @ticket.messages.create!(kind: :event, body: "#{@added_by.name} chamou #{@user.name} para acompanhar o chamado")
        @ticket.update!(last_activity_at: Time.current)
      end
      TicketNotifier.follower_added(@ticket, @user, added_by: @added_by)
      Result.new(success: true, error: nil)
    end

    private

    def failure(message) = Result.new(success: false, error: message)
  end
end
