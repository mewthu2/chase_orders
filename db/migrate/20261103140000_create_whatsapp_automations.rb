# Agente de IA no atendimento WhatsApp: automações por número, comandos ("quando… faça…"),
# perguntas que o agente não soube responder e a situação de cada conversa
# (pendente / respondendo / finalizado). Segura para rodar a qualquer momento.
class CreateWhatsappAutomations < ActiveRecord::Migration[7.2]
  def up
    unless table_exists?(:whatsapp_automations)
      create_table :whatsapp_automations do |t|
        t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
        t.references :created_by, foreign_key: { to_table: :users }
        t.string :name, null: false
        t.boolean :enabled, null: false, default: false
        t.string :mode, null: false, default: 'approve'
        t.text :instructions
        t.timestamps
      end
    end

    unless table_exists?(:whatsapp_automation_rules)
      create_table :whatsapp_automation_rules do |t|
        t.references :automation, null: false, foreign_key: { to_table: :whatsapp_automations }
        t.text :trigger, null: false
        t.text :response, null: false
        t.integer :position, null: false, default: 0
        t.boolean :active, null: false, default: true
        t.timestamps
      end
    end

    unless table_exists?(:whatsapp_automation_gaps)
      create_table :whatsapp_automation_gaps do |t|
        t.references :automation, null: false, foreign_key: { to_table: :whatsapp_automations }
        t.references :conversation, null: false, foreign_key: { to_table: :whatsapp_conversations }
        t.bigint :message_id
        t.references :rule, foreign_key: { to_table: :whatsapp_automation_rules }
        t.text :question, null: false
        t.string :state, null: false, default: 'open'
        t.timestamps
        t.index %i[automation_id state]
      end
    end

    add_column :whatsapp_conversations, :stage, :string, null: false, default: 'pending' unless column_exists?(:whatsapp_conversations, :stage)
    add_column :whatsapp_conversations, :agent_paused, :boolean, null: false, default: false unless column_exists?(:whatsapp_conversations, :agent_paused)
    add_column :whatsapp_conversations, :needs_human, :boolean, null: false, default: false unless column_exists?(:whatsapp_conversations, :needs_human)
    add_column :whatsapp_conversations, :agent_note, :string, limit: 500 unless column_exists?(:whatsapp_conversations, :agent_note)
    add_column :whatsapp_conversations, :agent_draft, :text unless column_exists?(:whatsapp_conversations, :agent_draft)
    add_column :whatsapp_conversations, :agent_draft_finish, :boolean, null: false, default: false unless column_exists?(:whatsapp_conversations, :agent_draft_finish)
    add_column :whatsapp_conversations, :agent_draft_for_id, :bigint unless column_exists?(:whatsapp_conversations, :agent_draft_for_id)
    add_index :whatsapp_conversations, :stage unless index_exists?(:whatsapp_conversations, :stage)
    add_column :whatsapp_messages, :by_agent, :boolean, null: false, default: false unless column_exists?(:whatsapp_messages, :by_agent)

    # Situação inicial das conversas que já existem.
    execute "UPDATE whatsapp_conversations SET stage = 'finished' WHERE state = 'closed'"
    execute <<~SQL.squish
      UPDATE whatsapp_conversations c SET c.stage = 'responding'
      WHERE c.state = 'open' AND (
        SELECT m.direction FROM whatsapp_messages m WHERE m.conversation_id = c.id
        ORDER BY m.sent_at DESC, m.id DESC LIMIT 1) = 'outgoing'
    SQL
  end

  def down
    remove_column :whatsapp_messages, :by_agent if column_exists?(:whatsapp_messages, :by_agent)
    %i[stage agent_paused needs_human agent_note agent_draft agent_draft_finish agent_draft_for_id].each do |col|
      remove_column :whatsapp_conversations, col if column_exists?(:whatsapp_conversations, col)
    end
    drop_table :whatsapp_automation_gaps, if_exists: true
    drop_table :whatsapp_automation_rules, if_exists: true
    drop_table :whatsapp_automations, if_exists: true
  end
end
