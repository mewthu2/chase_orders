module Whatsapp
  class Conversation < ApplicationRecord
    belongs_to :connection
    belongs_to :contact
    belongs_to :assignee, class_name: 'User', optional: true
    has_many :messages, dependent: :restrict_with_exception
    has_many :reads, dependent: :delete_all
    has_many :activities, dependent: :restrict_with_exception
    validates :state, inclusion: { in: %w[open closed] }
    validate { errors.add(:contact, 'de outro número') if contact && contact.connection_id != connection_id }

    def self.visible_to(user) = where(connection_id: Connection.visible_to(user).select(:id))
    def unread_count(user)
      cursor = reads.find_by(user_id: user.id)&.last_message_id || 0
      messages.where(direction: 'incoming', historical: false).where('id > ?', cursor).count
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
