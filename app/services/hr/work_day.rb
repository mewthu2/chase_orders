module Hr
  # Um dia de trabalho do funcionário montado a partir das marcações válidas: períodos trabalhados
  # (entrada → saída), intervalos, total, previsto pelo horário e saldo com a tolerância da CLT.
  # Enquanto a pessoa está "dentro" (última marcação é de entrada), o período aberto conta até agora,
  # desde que tenha começado há menos de 16h; depois disso é marcação faltando.
  class WorkDay
    TOLERANCE = 10 # CLT art. 58 §1º: até 5 min por marcação e 10 min no dia não contam
    OPEN_LIMIT = 16.hours

    attr_reader :employee, :date, :punches, :now

    def initialize(employee, date, punches = nil, now: Time.current)
      @employee = employee
      @date = date
      @now = now
      @punches = (punches || employee.valid_punches.where(work_date: date).to_a).reject(&:annulled?).sort_by { |p| [p.punched_at, p.id.to_i] }
      build
    end

    # [[início, fim]]; o fim é nil no período aberto que ainda conta (pessoa trabalhando agora).
    attr_reader :periods, :open_since

    def open? = open_since.present?
    def incomplete? = @incomplete
    def expected_minutes = employee.scheduled_minutes(date.wday)

    def worked_minutes
      periods.sum { |a, b| minutes_between(a, b || now) }
    end

    # Intervalos entre um período e o seguinte.
    def breaks = periods.each_cons(2).map { |(_, b), (c, _)| minutes_between(b, c) }
    def break_minutes = breaks.sum
    def longest_stretch = periods.map { |a, b| minutes_between(a, b || now) }.max.to_i

    # Saldo do dia (positivo = hora extra; negativo = falta), zerado dentro da tolerância.
    def balance
      diff = worked_minutes - expected_minutes
      diff.abs <= TOLERANCE && expected_minutes.positive? ? 0 : diff
    end

    def overtime = [balance, 0].max
    def first_in = periods.first&.first
    def last_out = periods.reverse.find { |_, b| b }&.last

    private

    def build
      @periods = []
      @incomplete = false
      start = nil
      punches.each do |p|
        if p.in?
          @incomplete = true if start # duas entradas seguidas: falta a saída da primeira
          start = p.punched_at
        elsif start
          @periods << [start, p.punched_at]
          start = nil
        else
          @incomplete = true # saída sem entrada
        end
      end
      return unless start

      if start > now - OPEN_LIMIT
        @open_since = start
        @periods << [start, nil]
      else
        @incomplete = true
      end
    end

    def minutes_between(a, b) = [((b - a) / 60).floor, 0].max
  end
end
