# Grupos do WhatsApp: guarda quem mandou cada mensagem (nome no WhatsApp ou telefone).
# Seguro para rodar a qualquer momento: só adiciona a coluna se faltar.
class AddSenderNameToWhatsappMessages < ActiveRecord::Migration[7.2]
  def up
    add_column :whatsapp_messages, :sender_name, :string, limit: 120 unless column_exists?(:whatsapp_messages, :sender_name)
  end

  def down
    remove_column :whatsapp_messages, :sender_name, if_exists: true
  end
end
