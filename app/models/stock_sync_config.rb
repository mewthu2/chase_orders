class StockSyncConfig < ApplicationRecord
  # Campos esperados na tabela:
  # - enabled: boolean (default: false)
  # - days_of_week: text (JSON array com dias da semana: 0=domingo, 1=segunda, etc)
  # - hours: text (JSON array com horas do dia: 0-23)
  # - last_execution: datetime
  # - created_at, updated_at

  validates :days_of_week, presence: true
  validates :hours, presence: true

  def self.current_config
    first_or_create(
      enabled: false,
      days_of_week: [1, 2, 3, 4, 5].to_json, # Segunda a sexta por padrão
      hours: [9, 14, 18].to_json # 9h, 14h, 18h por padrão
    )
  end

  def days_of_week_array
    JSON.parse(days_of_week || '[]')
  end

  def hours_array
    JSON.parse(hours || '[]')
  end

  def should_execute_now?
    return false unless enabled?

    now = Time.current
    current_day = now.wday
    current_hour = now.hour

    return false unless days_of_week_array.include?(current_day)

    return false unless hours_array.include?(current_hour)

    return false if last_execution && last_execution.to_date == now.to_date && last_execution.hour == current_hour

    true
  end

  def mark_as_executed!
    update!(last_execution: Time.current)
  end

  def days_of_week_names
    day_names = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado']
    days_of_week_array.map { |day| day_names[day] }
  end
end
