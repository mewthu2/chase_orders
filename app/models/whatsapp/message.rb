module Whatsapp
  class Message < ApplicationRecord
    belongs_to :connection
    belongs_to :conversation
    belongs_to :user, optional: true
    has_one :media, class_name: 'Whatsapp::Media', dependent: :restrict_with_exception
    validates :direction, inclusion: { in: %w[incoming outgoing] }
    validates :kind, inclusion: { in: %w[text image document audio unsupported] }
    validates :body, length: { maximum: 10_000 }
    validate { errors.add(:conversation, 'de outro número') if conversation && conversation.connection_id != connection_id }
    def preview = body.presence || { 'image' => 'Imagem', 'document' => 'Documento', 'audio' => 'Áudio' }.fetch(kind, 'Mensagem não suportada')
    def apply_receipt!(rank)
      return unless direction == 'outgoing' && rank.to_i > receipt_rank
      update!(receipt_rank: rank, state: { 1 => 'sent', 2 => 'delivered', 3 => 'read' }.fetch(rank.to_i))
    end
  end
end
