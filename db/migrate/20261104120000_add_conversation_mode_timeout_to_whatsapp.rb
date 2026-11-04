# Modo conversa com tempo: depois de X minutos sem a equipe escrever, o agente volta a sugerir.
# Segura para rodar a qualquer momento.
class AddConversationModeTimeoutToWhatsapp < ActiveRecord::Migration[7.2]
  def up
    unless column_exists?(:whatsapp_automations, :conversation_mode_minutes)
      add_column :whatsapp_automations, :conversation_mode_minutes, :integer, default: 30, null: false
    end
    unless column_exists?(:whatsapp_conversations, :agent_paused_at)
      add_column :whatsapp_conversations, :agent_paused_at, :datetime
      execute 'UPDATE whatsapp_conversations SET agent_paused_at = updated_at WHERE agent_paused = 1'
    end
  end

  def down
    remove_column :whatsapp_conversations, :agent_paused_at if column_exists?(:whatsapp_conversations, :agent_paused_at)
    remove_column :whatsapp_automations, :conversation_mode_minutes if column_exists?(:whatsapp_automations, :conversation_mode_minutes)
  end
end
