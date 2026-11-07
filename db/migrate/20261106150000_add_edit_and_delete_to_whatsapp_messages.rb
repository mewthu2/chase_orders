class AddEditAndDeleteToWhatsappMessages < ActiveRecord::Migration[7.2]
  def change
    add_column :whatsapp_messages, :edited_at, :datetime unless column_exists?(:whatsapp_messages, :edited_at)
    add_column :whatsapp_messages, :deleted_at, :datetime unless column_exists?(:whatsapp_messages, :deleted_at)
  end
end
