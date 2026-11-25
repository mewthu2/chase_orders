# Confere a jornada do dia depois de uma marcação de ponto (Hr::JourneyCheck) e, se a pessoa continua
# trabalhando, agenda a próxima conferência para o minuto em que ela cruzaria o próximo limite
# (carga do dia, 2h extras, 6h sem intervalo, carga da semana). Cada limite gera no máximo um alerta.
class HrJourneyCheckJob < ApplicationJob
  queue_as :default

  def perform(employee_id, date)
    employee = HrEmployee.find_by(id: employee_id) or return
    check = Hr::JourneyCheck.new(employee, Date.parse(date.to_s))
    check.call
    next_in = check.pending_thresholds.first
    self.class.set(wait: next_in.minutes).perform_later(employee_id, date.to_s) if next_in
  end
end
