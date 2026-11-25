# Recursos Humanos › Funcionário: empresa (das já cadastradas), estado onde trabalha (define o fuso do ponto),
# carga horária semanal e os horários de cada dia. Cada um tem um link próprio (punch_token) para bater o
# ponto com foto pela câmera do celular (PunchClockController).
class HrEmployee < ApplicationRecord
  # Dias na ordem da semana de trabalho (chave = wday do Ruby: 0 é domingo).
  WEEKDAYS = { '1' => 'Segunda', '2' => 'Terça', '3' => 'Quarta', '4' => 'Quinta', '5' => 'Sexta', '6' => 'Sábado', '0' => 'Domingo' }.freeze
  TIME_FIELDS = %w[in break_start break_end out].freeze
  TIME_FORMAT = /\A([01]\d|2[0-3]):[0-5]\d\z/

  # CF art. 7º XIII e CLT art. 58: 8h por dia e 44h por semana; com compensação (ex.: sábado livre) o dia
  # pode chegar a 10h (CLT art. 59, limite de 2h além das 8h).
  WEEKLY_LIMIT = 44 * 60
  DAY_LIMIT = 10 * 60

  # Fuso de cada estado: o horário do ponto é o do lugar onde a pessoa trabalha.
  STATE_ZONES = Hash.new('America/Sao_Paulo').merge(
    'AC' => 'America/Rio_Branco', 'AM' => 'America/Manaus', 'RR' => 'America/Boa_Vista', 'RO' => 'America/Porto_Velho',
    'MT' => 'America/Cuiaba', 'MS' => 'America/Campo_Grande'
  ).freeze

  belongs_to :company
  # Usuário do Honey que bate o ponto: o link só abre logado com ele.
  belongs_to :user, optional: true
  validates :user_id, uniqueness: { message: 'já está ligado a outro funcionário' }, allow_nil: true
  has_many :time_punches, class_name: 'HrTimePunch', dependent: :restrict_with_error
  has_many :alerts, class_name: 'HrAlert', dependent: :destroy

  before_validation :normalize
  before_validation :assign_token, on: :create

  validates :name, presence: true
  validates :state, inclusion: { in: Company::STATES.keys, message: 'escolha o estado' }
  validates :weekly_minutes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: WEEKLY_LIMIT,
                                             message: 'deve ficar entre 1h e 44h por semana (CF art. 7º, XIII)' }
  validates :punch_token, presence: true, uniqueness: true
  validate :cpf_checksum
  validate :schedule_is_valid

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  def time_zone = ActiveSupport::TimeZone[STATE_ZONES[state]]
  def now = Time.current.in_time_zone(time_zone)
  def today = now.to_date
  def first_name = name.to_s.split.first

  def company_name = company&.trade_name.presence || company&.legal_name

  # ---- horários ----
  def schedule_hash = (schedule.is_a?(Hash) ? schedule : {}).transform_keys(&:to_s)

  # Horário do dia (wday) ou nil quando é folga.
  def schedule_for(wday)
    day = schedule_hash[wday.to_s]
    day.is_a?(Hash) && day['in'].present? && day['out'].present? ? day : nil
  end

  def scheduled_minutes(wday)
    day = schedule_for(wday) or return 0
    span = self.class.span(day['in'], day['out'])
    span -= self.class.span(day['break_start'], day['break_end']) if day['break_start'].present? && day['break_end'].present?
    span
  end

  def scheduled_break_minutes(wday)
    day = schedule_for(wday)
    day && day['break_start'].present? && day['break_end'].present? ? self.class.span(day['break_start'], day['break_end']) : 0
  end

  def scheduled_weekly_minutes = WEEKDAYS.keys.sum { |d| scheduled_minutes(d) }
  def work_days = WEEKDAYS.keys.select { |d| schedule_for(d) }

  # Minutos entre dois "HH:MM" (passando da meia-noite quando o fim é menor que o início).
  def self.span(from, to)
    a = to_minutes(from)
    b = to_minutes(to)
    return 0 unless a && b

    b += 24 * 60 if b <= a
    b - a
  end

  def self.to_minutes(hhmm)
    return nil unless hhmm.to_s.match?(TIME_FORMAT)

    h, m = hhmm.split(':').map(&:to_i)
    h * 60 + m
  end

  def self.hours(minutes, sign: false)
    minutes = minutes.to_i
    text = format('%<h>dh%<m>02d', h: minutes.abs / 60, m: minutes.abs % 60)
    return "-#{text}" if minutes.negative?

    sign && minutes.positive? ? "+#{text}" : text
  end

  # Texto curto do horário do dia: "08:00–12:00 · 13:00–17:00".
  def schedule_text(wday)
    day = schedule_for(wday) or return 'Folga'
    return "#{day['in']}–#{day['out']}" if day['break_start'].blank?

    "#{day['in']}–#{day['break_start']} · #{day['break_end']}–#{day['out']}"
  end

  # Horas semanais digitadas no formulário ("44" ou "40:30").
  def weekly_hours = self.class.hours(weekly_minutes).sub('h00', 'h')

  def weekly_hours=(value)
    text = value.to_s.strip.tr(',', '.')
    self.weekly_minutes = if text.include?(':') || text.include?('h')
                            h, m = text.split(/[:h]/).map(&:to_i)
                            h * 60 + m.to_i
                          elsif text.present?
                            (text.to_f * 60).round
                          end
  end

  # ---- ponto ----
  def valid_punches = time_punches.where(annulled_at: nil)

  # Dia de trabalho de uma marcação: saída e volta do intervalo ficam no dia da entrada (turno que passa da
  # meia-noite); entrada é sempre do dia local.
  def work_date_for(kind, at = Time.current)
    local = at.in_time_zone(time_zone).to_date
    return local if kind.to_s == 'entrada'

    last = valid_punches.where('punched_at <= ?', at).order(punched_at: :desc).first
    last && last.punched_at > at - 16.hours ? last.work_date : local
  end

  # Próxima marcação esperada no link, pela última do dia.
  def suggested_kind(punches_today)
    last = punches_today.max_by(&:punched_at)
    case last&.kind
    when nil, 'saida' then 'entrada'
    when 'entrada' then schedule_for(today.wday)&.dig('break_start').present? && punches_today.none? { |p| p.kind == 'saida_intervalo' } ? 'saida_intervalo' : 'saida'
    when 'saida_intervalo' then 'volta_intervalo'
    when 'volta_intervalo' then 'saida'
    end
  end

  def regenerate_token!
    update!(punch_token: self.class.new_token)
  end

  def self.new_token = SecureRandom.urlsafe_base64(18)

  def cpf_formatted
    d = cpf.to_s.gsub(/\D/, '')
    d.size == 11 ? "#{d[0, 3]}.#{d[3, 3]}.#{d[6, 3]}-#{d[9, 2]}" : cpf.to_s
  end

  private

  def assign_token
    self.punch_token = self.class.new_token if punch_token.blank?
  end

  def normalize
    self.name = name.to_s.squish
    self.state = state.to_s.upcase.strip
    self.cpf = cpf.to_s.gsub(/\D/, '').presence
    self.email = email.to_s.strip.downcase.presence
    self.schedule = WEEKDAYS.keys.to_h do |d|
      day = schedule_hash[d]
      day = day.respond_to?(:to_unsafe_h) ? day.to_unsafe_h : day.to_h
      [d, TIME_FIELDS.to_h { |f| [f, day[f].to_s.strip.presence] }.compact]
    end.reject { |_, day| day.empty? }
  end

  def cpf_checksum
    return if cpf.blank?

    d = cpf.chars.map(&:to_i)
    valid = cpf.size == 11 && cpf.squeeze.size > 1 && [9, 10].all? do |n|
      sum = (0...n).sum { |i| d[i] * (n + 1 - i) }
      ((sum * 10) % 11) % 10 == d[n]
    end
    errors.add(:cpf, 'inválido') unless valid
  end

  # Regras da CLT para o horário contratado de cada dia.
  def schedule_is_valid
    if work_days.empty?
      errors.add(:schedule, 'informe a entrada e a saída de pelo menos um dia')
      return
    end

    WEEKDAYS.each do |d, label|
      day = schedule_hash[d] or next
      bad = day.select { |_, v| v.present? && !v.match?(TIME_FORMAT) }.keys
      next errors.add(:schedule, "de #{label}: horário inválido (use HH:MM)") if bad.any?
      next errors.add(:schedule, "de #{label}: informe a entrada e a saída") if day['in'].blank? ^ day['out'].blank?
      next errors.add(:schedule, "de #{label}: informe o início e o fim do intervalo") if day['break_start'].blank? ^ day['break_end'].blank?

      worked = scheduled_minutes(d)
      pause = scheduled_break_minutes(d)
      errors.add(:schedule, "de #{label}: #{self.class.hours(worked)} de trabalho passam do limite de 10h por dia (CLT art. 59)") if worked > DAY_LIMIT
      if worked > 6 * 60 && pause < 60
        errors.add(:schedule, "de #{label}: jornada acima de 6h precisa de intervalo de pelo menos 1h (CLT art. 71)")
      elsif worked > 4 * 60 && worked <= 6 * 60 && pause.positive? && pause < 15
        errors.add(:schedule, "de #{label}: jornada de 4h a 6h precisa de intervalo de 15 minutos (CLT art. 71 §1º)")
      end
    end
    return unless weekly_minutes.to_i.positive? && scheduled_weekly_minutes > weekly_minutes.to_i

    errors.add(:schedule, "somam #{self.class.hours(scheduled_weekly_minutes)} na semana, mais que a carga de #{self.class.hours(weekly_minutes)}")
  end
end
