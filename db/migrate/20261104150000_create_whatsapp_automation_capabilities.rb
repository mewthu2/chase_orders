# Funcionalidades do agente por automação: uma classe de pergunta ("quando a cliente perguntar…") ligada a uma
# consulta de verdade (estoque nas lojas, pedido na Shopify). Nascem desligadas. Segura para rodar a qualquer momento.
class CreateWhatsappAutomationCapabilities < ActiveRecord::Migration[7.2]
  def up
    return if table_exists?(:whatsapp_automation_capabilities)

    create_table :whatsapp_automation_capabilities do |t|
      t.references :automation, null: false, foreign_key: { to_table: :whatsapp_automations }
      t.string :key, null: false
      t.boolean :enabled, null: false, default: false
      t.text :trigger
      t.timestamps
    end
    add_index :whatsapp_automation_capabilities, [:automation_id, :key], unique: true, name: 'index_wa_capabilities_on_automation_and_key'
  end

  def down
    drop_table :whatsapp_automation_capabilities if table_exists?(:whatsapp_automation_capabilities)
  end
end
