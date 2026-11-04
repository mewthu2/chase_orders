# Modo conversa passa a desligar sozinho depois de 10 minutos (padrão e automações que estavam no padrão antigo, 30).
# Segura para rodar a qualquer momento.
class ConversationModeTenMinutes < ActiveRecord::Migration[7.2]
  def up
    return unless column_exists?(:whatsapp_automations, :conversation_mode_minutes)

    change_column_default :whatsapp_automations, :conversation_mode_minutes, from: 30, to: 10
    execute 'UPDATE whatsapp_automations SET conversation_mode_minutes = 10 WHERE conversation_mode_minutes = 30'
  end

  def down
    change_column_default :whatsapp_automations, :conversation_mode_minutes, from: 10, to: 30
  end
end
