# Alerta de jornada (Hr::JourneyCheck): um por funcionário, dia e tipo. O e-mail sai uma vez só,
# quando o alerta nasce; se o excesso aumentar no mesmo dia, o alerta é atualizado sem novo e-mail.
# Nos alertas da semana, work_date é a segunda-feira.
class HrAlert < ApplicationRecord
  KINDS = {
    'daily_over'  => { label: 'Acima da carga do dia',            tone: 'yellow', emoji: '⏰', law: 'CLT art. 58 §1º: variação acima de 10 minutos no dia conta como hora extra.' },
    'day_off'     => { label: 'Trabalhou na folga',               tone: 'yellow', emoji: '📅', law: 'Dia sem horário contratado: todo o tempo é hora extra (CLT art. 67 e 70 no domingo/feriado).' },
    'daily_limit' => { label: 'Passou do limite legal do dia',    tone: 'red',    emoji: '🚨', law: 'CLT art. 59: no máximo 2 horas extras por dia (até 10h de trabalho).' },
    'weekly_over' => { label: 'Acima da carga semanal',           tone: 'yellow', emoji: '📈', law: 'CF art. 7º XIII: carga contratada, com teto de 44h por semana.' },
    'break_short' => { label: 'Intervalo abaixo do mínimo',       tone: 'red',    emoji: '🍽️', law: 'CLT art. 71: jornada acima de 6h exige intervalo de 1h (de 4h a 6h, 15 minutos).' },
    'rest_short'  => { label: 'Descanso entre jornadas < 11h',    tone: 'red',    emoji: '😴', law: 'CLT art. 66: 11 horas seguidas de descanso entre duas jornadas.' }
  }.freeze

  belongs_to :employee, class_name: 'HrEmployee', foreign_key: :hr_employee_id, inverse_of: :alerts

  validates :kind, inclusion: { in: KINDS.keys }

  scope :recent, -> { order(work_date: :desc, created_at: :desc) }

  def label = KINDS.dig(kind, :label)
  def tone = KINDS.dig(kind, :tone)
  def law = KINDS.dig(kind, :law)
  def emoji = KINDS.dig(kind, :emoji)
  def weekly? = kind == 'weekly_over'
  def period_text = weekly? ? "Semana de #{work_date.strftime('%d/%m')} a #{(work_date + 6).strftime('%d/%m/%Y')}" : work_date.strftime('%d/%m/%Y')
end
