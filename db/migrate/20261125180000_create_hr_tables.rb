# Recursos Humanos: funcionários por empresa e estado (carga horária e horários), as marcações de ponto
# feitas pelo link de cada um (com foto) e os alertas de jornada acima da carga ou dos limites da CLT.
class CreateHrTables < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:hr_employees)
      create_table :hr_employees do |t|
        t.string :name, null: false
        t.string :cpf, limit: 14
        t.string :role
        t.string :email
        t.string :phone, limit: 30
        t.references :company, null: false, foreign_key: true
        t.string :state, limit: 2, null: false
        t.date :admission_date
        t.integer :weekly_minutes, null: false, default: 2640
        # { "1" => { "in" => "08:00", "break_start" => "12:00", "break_end" => "13:00", "out" => "17:00" }, ... } (0 = domingo)
        t.json :schedule
        t.string :punch_token, null: false
        t.boolean :active, null: false, default: true
        t.timestamps
      end
      add_index :hr_employees, :punch_token, unique: true
      add_index :hr_employees, :cpf
    end

    unless table_exists?(:hr_time_punches)
      create_table :hr_time_punches do |t|
        t.references :hr_employee, null: false, foreign_key: true
        t.string :kind, null: false, limit: 20
        t.datetime :punched_at, null: false
        t.date :work_date, null: false
        t.bigint :nsr, null: false
        t.string :source, null: false, default: 'link', limit: 10
        t.string :ip, limit: 64
        t.string :user_agent
        t.references :created_by, foreign_key: { to_table: :users }
        t.text :note
        t.datetime :annulled_at
        t.references :annulled_by, foreign_key: { to_table: :users }
        t.text :annul_reason
        t.timestamps
      end
      add_index :hr_time_punches, %i[hr_employee_id work_date]
      add_index :hr_time_punches, :nsr, unique: true
    end

    unless table_exists?(:hr_alerts)
      create_table :hr_alerts do |t|
        t.references :hr_employee, null: false, foreign_key: true
        t.date :work_date, null: false
        t.string :kind, null: false, limit: 30
        t.integer :minutes
        t.text :message
        t.datetime :notified_at
        t.timestamps
      end
      add_index :hr_alerts, %i[hr_employee_id work_date kind], unique: true
      add_index :hr_alerts, :work_date
    end
  end
end
