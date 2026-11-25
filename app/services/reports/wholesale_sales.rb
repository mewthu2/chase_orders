module Reports
  # Vendas do atacado para o painel Adm › Dashboards e relatórios › Vendas Atacado. Venda concretizada = NF-e de
  # venda (pedido de atacado, nota principal, sem as de remessa) autorizada em produção, na data de emissão, pelo
  # valor da nota (produtos + frete + despesas - desconto). Cancelada não conta como venda; aparece à parte.
  # Peças, produtos e vendedor saem do pedido da nota.
  class WholesaleSales
    Period = Struct.new(:key, :label, :range, :previous, :granularity, keyword_init: true)

    def self.period(param, today: Date.current)
      param = param.to_s
      if (m = param.match(/\A(\d{4})-(\d{2})\z/))
        month = Date.new(m[1].to_i, m[2].to_i, 1)
        prev = month.prev_month
        return Period.new(key: param, label: I18n.l(month, format: '%B de %Y').capitalize, range: month..month.end_of_month,
                          previous: prev..prev.end_of_month, granularity: :day)
      end
      if (m = param.match(/\Aano-(\d{4})\z/))
        year = Date.new(m[1].to_i, 1, 1)
        return Period.new(key: param, label: "Ano de #{year.year}", range: year..year.end_of_year,
                          previous: year.prev_year..year.prev_year.end_of_year, granularity: :month)
      end
      if param == '12m'
        start = today.beginning_of_month << 11
        return Period.new(key: '12m', label: 'Últimos 12 meses', range: start..today, previous: (start << 12)..(start - 1), granularity: :month)
      end
      if param == '30d'
        return Period.new(key: '30d', label: 'Últimos 30 dias', range: (today - 29)..today, previous: (today - 59)..(today - 30), granularity: :day)
      end

      period(today.strftime('%Y-%m'), today: today)
    end

    # [[rótulo, valor], ...] para o select (options_for_select).
    def self.period_options(today: Date.current)
      months = (0..23).map { |i| today.beginning_of_month << i }
      [['Últimos 30 dias', '30d'], ['Últimos 12 meses', '12m']] +
        [today.year, today.year - 1].map { |y| ["Ano de #{y}", "ano-#{y}"] } +
        months.map { |m| [I18n.l(m, format: '%B de %Y').capitalize, m.strftime('%Y-%m')] }
    end

    def initialize(period)
      @period = period
    end

    attr_reader :period

    def notes(range = period.range, status: :autorizada)
      FiscalNote.principal.producao.where(status: status).joins(:b2b_order).where(b2b_orders: { kind: B2bOrder.kinds[:sale] })
                .where('COALESCE(fiscal_notes.issued_at, fiscal_notes.authorized_at, fiscal_notes.created_at) BETWEEN ? AND ?',
                       range.begin.beginning_of_day, range.end.end_of_day)
    end

    def current = @current ||= summary(load(notes))
    def previous = @previous ||= summary(load(notes(period.previous)))

    def cancelled
      @cancelled ||= begin
        list = notes(status: :cancelada)
        { count: list.count, value: list.sum(:total_value).to_f }
      end
    end

    # Faturamento por dia (mês ou 30 dias) ou por mês (ano ou 12 meses), com os dias/meses sem venda em zero.
    def timeline
      @timeline ||= begin
        rows = load(notes)
        buckets = if period.granularity == :day
                    period.range.to_a.map { |d| [d, d.strftime('%d/%m'), I18n.l(d, format: '%a, %d/%m')] }
                  else
                    months = []
                    m = period.range.begin.beginning_of_month
                    while m <= period.range.end
                      months << [m, I18n.l(m, format: '%b/%y').capitalize, I18n.l(m, format: '%B de %Y').capitalize]
                      m = m.next_month
                    end
                    months
                  end
        key = period.granularity == :day ? ->(d) { d } : ->(d) { d.beginning_of_month }
        sums = rows.group_by { |r| key.call(r[:date]) }.transform_values { |rs| [rs.sum { |r| r[:value] }, rs.size] }
        buckets.map { |d, short, long| { date: d, short: short, long: long, value: sums.dig(key.call(d), 0).to_f, count: sums.dig(key.call(d), 1).to_i } }
      end
    end

    # Últimos 12 meses fechados até o fim do período, para ver a tendência mesmo olhando um mês só.
    def monthly_trend
      @monthly_trend ||= begin
        last = period.range.end.beginning_of_month
        first = last << 11
        rows = load(notes(first..last.end_of_month))
        sums = rows.group_by { |r| r[:date].beginning_of_month }.transform_values { |rs| rs.sum { |r| r[:value] } }
        (0..11).map do |i|
          m = first >> i
          { date: m, short: I18n.l(m, format: '%b/%y').capitalize, long: I18n.l(m, format: '%B de %Y').capitalize, value: sums[m].to_f }
        end
      end
    end

    def top_clients(limit = 10) = ranking(current[:rows], limit) { |r| r[:client] }
    def by_state = ranking(current[:rows], 27) { |r| r[:state] }
    def by_payment = ranking(current[:rows], 10) { |r| r[:payment] }
    def by_seller = ranking(current[:rows], 10) { |r| r[:seller] }
    def by_consultant = ranking(current[:rows], 10) { |r| r[:consultant] }

    # Produtos pelo modelo (o nome sem o tamanho do fim: "TAILOR V OLIVE NIGHT - P" → "TAILOR V OLIVE NIGHT"),
    # com o valor dos itens (preço × quantidade - desconto) e as peças.
    def top_products(limit = 10)
      @top_products ||= begin
        items = current[:rows].flat_map { |r| r[:items] }
        total = items.sum { |i| i[:value] }
        items.group_by { |i| i[:model] }.map do |model, list|
          value = list.sum { |i| i[:value] }
          { label: model, value: value, pieces: list.sum { |i| i[:qty] }, skus: list.map { |i| i[:sku] }.uniq.size,
            share: total.positive? ? value / total : 0 }
        end.sort_by { |x| -x[:value] }.first(limit)
      end
    end

    def delta(key)
      now = current[key].to_f
      before = previous[key].to_f
      return nil if before.zero?

      (now - before) / before
    end

    private

    def load(scope)
      scope.includes(b2b_order: %i[client user consultant b2b_order_items]).to_a.map do |note|
        order = note.b2b_order
        { id: note.id, order_id: order.id, value: note.total_value.to_f, date: (note.issued_at || note.authorized_at || note.created_at).in_time_zone.to_date,
          client: client_label(order), client_id: order.client_id, state: order.client&.state.presence&.upcase || 'Sem UF',
          payment: order.payment_label || 'Sem forma', seller: order.user&.name || 'Sem vendedor',
          consultant: order.consultant_label || 'Sem consultor',
          items: order.b2b_order_items.map do |i|
            { sku: i.sku, model: model_of(i), qty: i.quantity.to_i, value: (i.price.to_f * i.quantity.to_i) - i.discount.to_f }
          end }
      end
    end

    def summary(rows)
      orders = rows.uniq { |r| r[:order_id] }
      revenue = rows.sum { |r| r[:value] }
      { rows: rows, revenue: revenue, notes: rows.size, orders: orders.size, ticket: orders.any? ? revenue / orders.size : 0,
        pieces: orders.sum { |r| r[:items].sum { |i| i[:qty] } }, clients: rows.map { |r| r[:client_id] || r[:client] }.uniq.size }
    end

    def ranking(rows, limit, &key)
      total = rows.sum { |r| r[:value] }
      rows.group_by(&key).map do |label, list|
        value = list.sum { |r| r[:value] }
        { label: label, value: value, count: list.size, share: total.positive? ? value / total : 0 }
      end.sort_by { |x| -x[:value] }.first(limit)
    end

    def client_label(order)
      c = order.client
      return 'Sem cliente' unless c

      c.business_name.presence || c.responsible_name
    end

    def model_of(item)
      name = item.name.presence || item.sku.to_s
      name.sub(/\s+-\s+(PP|P|M|G|GG|XG|XGG|EG|U|UN|\d{1,2})\s*\z/i, '').strip
    end
  end
end
