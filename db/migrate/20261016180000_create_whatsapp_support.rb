class CreateWhatsappSupport < ActiveRecord::Migration[7.2]
  def change
    opts = { charset: 'utf8mb4', collation: 'utf8mb4_bin' }
    create_table :whatsapp_connections, **opts do |t|
      t.string :name, null: false
      t.string :provider, null: false, default: 'evolution'
      t.string :instance_key, null: false
      t.text :webhook_token, null: false
      t.string :phone
      t.string :state, null: false, default: 'disconnected'
      t.boolean :enabled, null: false, default: true
      t.text :qr_data
      t.datetime :qr_expires_at
      t.datetime :provider_updated_at
      t.datetime :last_event_at
      t.datetime :last_synced_at
      t.datetime :sync_requested_at
      t.string :control_action
      t.integer :control_version, null: false, default: 0
      t.string :error_code
      t.timestamps
    end
    add_index :whatsapp_connections, :instance_key, unique: true
    create_table :whatsapp_memberships do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :whatsapp_memberships, [:connection_id, :user_id], unique: true, name: 'idx_wa_membership_unique'
    create_table :whatsapp_contacts, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.references :customer, foreign_key: true
      t.string :provider_jid, null: false, limit: 191
      t.string :phone
      t.string :name
      t.timestamps
    end
    add_index :whatsapp_contacts, [:connection_id, :provider_jid], unique: true, name: 'idx_wa_contact_unique'
    add_index :whatsapp_contacts, :phone
    create_table :whatsapp_contact_aliases, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.references :contact, null: false, foreign_key: { to_table: :whatsapp_contacts }
      t.string :jid, null: false, limit: 191
    end
    add_index :whatsapp_contact_aliases, [:connection_id, :jid], unique: true, name: 'idx_wa_alias_unique'
    create_table :whatsapp_conversations, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.references :contact, null: false, foreign_key: { to_table: :whatsapp_contacts }
      t.references :assignee, foreign_key: { to_table: :users }
      t.string :state, null: false, default: 'open'
      t.datetime :last_message_at
      t.string :last_message_preview
      t.timestamps
    end
    add_index :whatsapp_conversations, [:connection_id, :contact_id], unique: true, name: 'idx_wa_conversation_unique'
    add_index :whatsapp_conversations, [:connection_id, :last_message_at], name: 'idx_wa_inbox'
    create_table :whatsapp_messages, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.references :conversation, null: false, foreign_key: { to_table: :whatsapp_conversations }
      t.references :user, foreign_key: true
      t.string :provider_id, limit: 191
      t.string :client_nonce, limit: 64
      t.string :direction, null: false
      t.string :kind, null: false, default: 'text'
      t.text :body
      t.string :state, null: false
      t.integer :receipt_rank, null: false, default: 0
      t.boolean :historical, null: false, default: false
      t.datetime :sent_at, null: false
      t.datetime :attempted_at
      t.string :error_code
      t.string :media_state
      t.integer :media_attempts, null: false, default: 0
      t.datetime :media_retry_at
      t.json :provider_key
      t.timestamps
    end
    add_index :whatsapp_messages, [:connection_id, :provider_id], unique: true, name: 'idx_wa_provider_message'
    add_index :whatsapp_messages, [:connection_id, :client_nonce], unique: true, name: 'idx_wa_client_message'
    add_index :whatsapp_messages, [:conversation_id, :sent_at, :id], name: 'idx_wa_history'
    add_index :whatsapp_messages, [:media_state, :media_retry_at], name: 'idx_wa_pending_media'
    add_index :whatsapp_messages, [:state, :attempted_at], name: 'idx_wa_pending_sends'
    create_table :whatsapp_reads do |t|
      t.references :conversation, null: false, foreign_key: { to_table: :whatsapp_conversations }
      t.references :user, null: false, foreign_key: true
      t.bigint :last_message_id, null: false, default: 0
    end
    add_index :whatsapp_reads, [:conversation_id, :user_id], unique: true, name: 'idx_wa_read_unique'
    create_table :whatsapp_receipts, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.string :provider_id, null: false, limit: 191
      t.integer :rank, null: false, default: 0
      t.timestamps
    end
    add_index :whatsapp_receipts, [:connection_id, :provider_id], unique: true, name: 'idx_wa_receipt_unique'
    create_table :whatsapp_events, **opts do |t|
      t.references :connection, null: false, foreign_key: { to_table: :whatsapp_connections }
      t.string :digest, null: false, limit: 64
      t.string :kind, null: false
      t.text :payload, limit: 16.megabytes, null: false
      t.datetime :occurred_at, null: false
      t.datetime :processed_at
      t.integer :attempts, null: false, default: 0
      t.string :error_code
      t.timestamps
    end
    add_index :whatsapp_events, [:connection_id, :digest], unique: true, name: 'idx_wa_event_unique'
    add_index :whatsapp_events, [:processed_at, :attempts], name: 'idx_wa_pending_events'
    create_table :whatsapp_media, **opts do |t|
      t.references :message, null: false, foreign_key: { to_table: :whatsapp_messages }, index: { unique: true }
      t.string :storage_key, null: false
      t.string :service_name, null: false
      t.string :filename, null: false
      t.string :content_type, null: false
      t.bigint :byte_size, null: false
      t.timestamps
    end
    add_index :whatsapp_media, :storage_key, unique: true
    create_table :whatsapp_activities do |t|
      t.references :conversation, null: false, foreign_key: { to_table: :whatsapp_conversations }
      t.references :user, null: false, foreign_key: true
      t.string :action, null: false
      t.references :assignee, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
