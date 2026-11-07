module Whatsapp
  class Message < ApplicationRecord
    belongs_to :connection
    belongs_to :conversation
    belongs_to :user, optional: true
    has_one :media, class_name: 'Whatsapp::Media', dependent: :restrict_with_exception
    validates :direction, inclusion: { in: %w[incoming outgoing] }
    validates :kind, inclusion: { in: %w[text image document audio video unsupported] }
    validates :body, length: { maximum: 10_000 }
    validate { errors.add(:conversation, 'de outro número') if conversation && conversation.connection_id != connection_id }
    # Limites do próprio WhatsApp: editar até 15 minutos, apagar para todos até ~2 dias.
    EDIT_WINDOW = 15.minutes
    DELETE_WINDOW = 2.days
    def deleted? = deleted_at.present?
    def edited? = edited_at.present?
    # Só quem escreveu, e só depois que o WhatsApp confirmou o envio.
    def own_sent?(user)
      direction == 'outgoing' && !by_agent? && user && user_id == user.id && provider_id.present? &&
        %w[sent delivered read].include?(state) && !deleted?
    end
    def editable_by?(user) = own_sent?(user) && kind == 'text' && sent_at > EDIT_WINDOW.ago
    def deletable_by?(user) = own_sent?(user) && sent_at > DELETE_WINDOW.ago
    def author_name = by_agent? ? 'Agente Honey' : user&.name
    def preview = deleted? ? 'Mensagem apagada' : body.presence || { 'image' => 'Imagem', 'document' => 'Documento', 'audio' => 'Áudio', 'video' => 'Vídeo' }.fetch(kind, 'Mensagem não suportada')
    def apply_receipt!(rank)
      return unless direction == 'outgoing' && rank.to_i > receipt_rank
      update!(receipt_rank: rank, state: { 1 => 'sent', 2 => 'delivered', 3 => 'read' }.fetch(rank.to_i))
    end
  end
end
