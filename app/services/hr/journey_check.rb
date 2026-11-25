module Hr
  # Confere a jornada de um dia contra a carga horária e os limites da CLT e cria os alertas (HrAlert).
  # Os alertas novos vão por e-mail para o RH (HrMailer). Roda depois de cada marcação (HrJourneyCheckJob)
  # e de novo quando a pessoa, ainda sem bater a saída, vai cruzar um limite (schedule_followups).
  class JourneyCheck
    EXTRA_LIMIT = 120          # CLT art. 59: até 2h extras por dia
    DAY_LIMIT = 10 * 60
    REST_MIN = 11 * 60         # CLT art. 66
    STRETCH_LIMIT = 6 * 60     # CLT art. 71: acima de 6h seguidas sem intervalo de 1h

    def self.call(employee, date, now: Time.current, notify: true)
      new(employee, date, now: now).call(notify: notify)
    end

    def initialize(employee, date, now: Time.current)
      @employee = employee
      @date = date
      @now = now
      @day = WorkDay.new(employee, date, now: now)
    end

    attr_reader :day

    # Devolve os alertas criados agora.
    def call(notify: true)
      created = findings.filter_map { |kind, date, minutes, message| record(kind, date, minutes, message) }
      if notify && created.any?
        HrMailer.with(alerts: created).journey_alert.deliver_now
        HrAlert.where(id: created.map(&:id)).update_all(notified_at: Time.current)
      end
      created
    end

    # Minutos até cada limite que a pessoa ainda vai cruzar se não bater a saída (para reagendar a conferência).
    def pending_thresholds
      return [] unless day.open?

      worked = day.worked_minutes
      expected = day.expected_minutes
      limits = [expected + WorkDay::TOLERANCE + 1, legal_day_limit + 1]
      limits << weekly_limit_left + 1 if weekly_limit_left
      stretch_left = STRETCH_LIMIT + 1 - day.longest_stretch
      ([stretch_left] + limits.map { |l| l - worked }).select(&:positive?).uniq.sort
    end

    private

    def findings
      list = []
      worked = day.worked_minutes
      expected = day.expected_minutes
      h = ->(m) { HrEmployee.hours(m) }
      ongoing = day.open? ? ' (ainda sem bater a saída)' : ''

      if expected.zero? && worked.positive?
        list << ['day_off', @date, worked, "Trabalhou #{h.(worked)} num dia de folga#{ongoing}."]
      elsif day.overtime.positive?
        list << ['daily_over', @date, day.overtime, "Trabalhou #{h.(worked)} para #{h.(expected)} previstas: #{h.(day.overtime)} acima da carga#{ongoing}."]
      end
      if worked > legal_day_limit
        list << ['daily_limit', @date, worked - legal_day_limit,
                 "Trabalhou #{h.(worked)}, acima do limite legal de #{h.(legal_day_limit)} no dia (carga + 2h extras, máx. 10h)#{ongoing}."]
      end
      if (msg = break_problem(worked))
        list << ['break_short', @date, day.break_minutes, msg]
      end
      if (rest = rest_before) && rest < REST_MIN
        list << ['rest_short', @date, rest, "Descansou só #{h.(rest)} entre a última saída e a entrada de #{@date.strftime('%d/%m')} (mínimo 11h)."]
      end
      week_worked, week_start = week_total
      if week_worked > @employee.weekly_minutes + WorkDay::TOLERANCE
        over = week_worked - @employee.weekly_minutes
        list << ['weekly_over', week_start, over,
                 "Trabalhou #{h.(week_worked)} na semana para carga de #{h.(@employee.weekly_minutes)}: #{h.(over)} acima."]
      end
      list
    end

    def legal_day_limit
      expected = day.expected_minutes
      expected.positive? ? [expected + EXTRA_LIMIT, DAY_LIMIT].min : DAY_LIMIT
    end

    def break_problem(worked)
      return "Está há #{HrEmployee.hours(day.longest_stretch)} seguidas sem intervalo (máximo de 6h sem pausa)." if day.longest_stretch > STRETCH_LIMIT
      return nil if day.open?

      if worked > 6 * 60 && day.break_minutes < 60
        "Jornada de #{HrEmployee.hours(worked)} com #{HrEmployee.hours(day.break_minutes)} de intervalo (mínimo de 1h)."
      elsif worked > 4 * 60 && worked <= 6 * 60 && day.periods.size > 1 && day.break_minutes < 15
        "Jornada de #{HrEmployee.hours(worked)} com #{day.break_minutes} min de intervalo (mínimo de 15 min)."
      end
    end

    # Minutos entre a última saída antes do dia e a primeira entrada dele.
    def rest_before
      first = day.first_in or return nil
      previous = @employee.valid_punches.where('punched_at < ?', first).where.not(work_date: @date).order(punched_at: :desc).first
      return nil unless previous&.out?

      ((first - previous.punched_at) / 60).floor
    end

    def week_start = @date.beginning_of_week(:monday)

    def week_total
      punches = @employee.valid_punches.where(work_date: week_start..@date).to_a.group_by(&:work_date)
      total = punches.sum { |date, list| date == @date ? day.worked_minutes : WorkDay.new(@employee, date, list, now: @now).worked_minutes }
      [total, week_start]
    end

    def weekly_limit_left
      week_worked, = week_total
      @employee.weekly_minutes + WorkDay::TOLERANCE - week_worked + day.worked_minutes
    end

    def record(kind, date, minutes, message)
      alert = @employee.alerts.find_or_initialize_by(work_date: date, kind: kind)
      fresh = alert.new_record?
      alert.assign_attributes(minutes: minutes, message: message)
      alert.save! if fresh || alert.changed?
      fresh ? alert : nil
    rescue ActiveRecord::RecordNotUnique
      nil
    end
  end
end
