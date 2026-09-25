# Interação no chamado. `comment` é escrita por alguém; `event` é um registro automático
# (ex.: "Fulano chamou Ciclano para acompanhar").
class TicketMessage < ApplicationRecord
  include HasTicketAttachments

  enum :kind, { comment: 0, event: 1 }

  belongs_to :ticket
  belongs_to :user, optional: true

  validate :comment_must_have_content, if: :comment?

  def status_changed? = status_to.present?
  def status_from_name = Ticket.statuses.key(status_from)
  def status_to_name = Ticket.statuses.key(status_to)

  private

  def comment_must_have_content
    return if body.present? || attachments.attached? || status_to.present?

    errors.add(:base, 'Escreva uma mensagem, anexe um arquivo ou altere o status')
  end
end
