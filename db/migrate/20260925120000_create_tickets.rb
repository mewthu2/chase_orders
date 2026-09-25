class CreateTickets < ActiveRecord::Migration[7.2]
  # Sistema de chamados: responsabilidades (áreas com responsáveis fixos e prazo de resposta),
  # chamados, participantes (solicitante/responsável/acompanhante) e interações.
  def change
    create_table :ticket_responsabilities do |t|
      t.string :name, null: false
      t.text :description
      t.integer :response_time_hours, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :ticket_responsabilities, :name, unique: true

    create_table :ticket_responsability_users do |t|
      t.references :ticket_responsability, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :ticket_responsability_users, [:ticket_responsability_id, :user_id], unique: true, name: 'index_ticket_resp_users_on_resp_and_user'

    create_table :tickets do |t|
      t.string :title, null: false
      t.text :description, null: false
      t.references :ticket_responsability, null: false, foreign_key: true
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.integer :status, null: false, default: 0
      t.datetime :due_at
      t.datetime :overdue_notified_at
      t.text :solution
      t.datetime :resolved_at
      t.datetime :closed_at
      t.datetime :last_activity_at
      t.timestamps
    end
    add_index :tickets, :status
    add_index :tickets, :due_at

    create_table :ticket_participants do |t|
      t.references :ticket, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :role, null: false, default: 0
      t.timestamps
    end
    add_index :ticket_participants, [:ticket_id, :user_id], unique: true

    create_table :ticket_messages do |t|
      t.references :ticket, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.integer :kind, null: false, default: 0
      t.text :body
      t.integer :status_from
      t.integer :status_to
      t.timestamps
    end

    add_column :users, :ticket_notifications_enabled, :boolean, null: false, default: true
  end
end
