class AddAttendanceSummaryToWhatsappConversations < ActiveRecord::Migration[7.2]
  def change
    add_column :whatsapp_conversations, :attendance_summary, :text
    add_column :whatsapp_conversations, :attendance_summary_version, :integer, default: 0, null: false
    add_column :whatsapp_conversations, :attendance_summary_updated_at, :datetime
    add_reference :whatsapp_conversations, :attendance_summary_author,
      foreign_key: { to_table: :users, on_delete: :nullify }, index: { name: 'idx_wa_summary_author' }
  end
end
