module Whatsapp
  class Conversation < ApplicationRecord
    belongs_to :connection
    belongs_to :contact
    belongs_to :assignee, class_name: 'User', optional: true
    belongs_to :attendance_summary_author, class_name: 'User', optional: true
    has_many :messages, dependent: :restrict_with_exception
    has_many :reads, dependent: :delete_all
    has_many :activities, dependent: :restrict_with_exception
    validates :state, inclusion: { in: %w[open closed] }
    validates :attendance_summary, length: { maximum: 10_000, message: 'deve ter no máximo 10.000 caracteres.' }
    validate { errors.add(:contact, 'de outro número') if contact && contact.connection_id != connection_id }

    def self.visible_to(user) = where(connection_id: Connection.visible_to(user).select(:id))

    # A separate version prevents incoming messages and assignment changes from
    # conflicting with summary edits, while serializing edits by two attendants.
    def update_attendance_summary!(body:, version:, author:)
      with_lock do
        return false unless attendance_summary_version == version

        update!(attendance_summary: body, attendance_summary_version: version + 1,
          attendance_summary_author: author, attendance_summary_updated_at: Time.current)
      end
      true
    end

    def attendance_summary_payload
      { body: attendance_summary.to_s, version: attendance_summary_version,
        updated_at: attendance_summary_updated_at, author_name: attendance_summary_author&.name }
    end
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
