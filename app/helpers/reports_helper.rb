# Gráficos dos relatórios (Adm › Dashboards e relatórios), desenhados no servidor em SVG/HTML, sem biblioteca:
# uma série por gráfico (cor única, --rpt-c), barras finas com ponta arredondada, grade discreta, valor no
# data-tip (a dica do Honey) e a tabela do gráfico num <details>.
module ReportsHelper
  def rpt_money(value, compact: false)
    return number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.') unless compact

    v = value.to_f
    if v.abs >= 1_000_000 then "R$ #{number_with_precision(v / 1_000_000, precision: 1, separator: ',')} mi"
    elsif v.abs >= 1_000 then "R$ #{number_with_precision(v / 1_000, precision: 1, separator: ',', strip_insignificant_zeros: true)} mil"
    else "R$ #{v.round}"
    end
  end

  def rpt_percent(share, precision: 1)
    "#{number_with_precision(share.to_f * 100, precision: precision, separator: ',', strip_insignificant_zeros: true)}%"
  end

  # Indicador com a variação contra o período anterior (seta + texto, nunca só cor).
  def rpt_kpi(label:, value:, icon:, help:, delta: nil, previous: nil, tone: 'blue', i: 0)
    badge = if delta.nil?
              content_tag(:span, 'sem base anterior', class: 'rpt-delta is-flat', data: { tip: 'O período anterior não teve venda para comparar.' })
            elsif delta.abs < 0.0005
              content_tag(:span, safe_join([content_tag(:i, '', class: 'fas fa-equals'), 'igual']), class: 'rpt-delta is-flat',
                          data: { tip: "Igual ao período anterior (#{previous})." })
            else
              up = delta >= 0
              content_tag(:span, safe_join([content_tag(:i, '', class: "fas fa-arrow-#{up ? 'up' : 'down'}"), rpt_percent(delta.abs)]),
                          class: "rpt-delta #{up ? 'is-up' : 'is-down'}", data: { tip: "#{up ? 'Subiu' : 'Caiu'} #{rpt_percent(delta.abs)} contra o período anterior (#{previous})." })
            end
    content_tag(:div, class: 'pg-kpi is-static spot', style: "--i: #{i}") do
      content_tag(:div, class: 'stat-card', style: "--tone: #{hc_tone(tone)}") do
        content_tag(:span, '', class: 'tone-bar') +
          content_tag(:div, content_tag(:span, label, class: 'ticket-stat__label') + content_tag(:span, content_tag(:i, '', class: icon), class: 'stat-ic'), class: 'stat-top') +
          content_tag(:div, value, class: 'stat-value is-text') +
          content_tag(:div, badge + content_tag(:span, help), class: 'stat-help rpt-help')
      end
    end
  end

  # Colunas no tempo (faturamento por dia ou por mês). points: [{ short:, long:, value:, count: }]
  def rpt_columns(points, title:, height: 220, empty: 'Sem venda no período.')
    w = 1100.0 # perto da largura real na tela: o texto do eixo fica no tamanho normal
    h = height.to_f
    pad_l = 64.0
    pad_b = 26.0
    pad_t = 10.0
    plot_w = w - pad_l - 8
    plot_h = h - pad_b - pad_t
    max = points.map { |p| p[:value] }.max.to_f
    return content_tag(:p, empty, class: 'rpt-empty') if max <= 0

    top = rpt_nice_max(max)
    slot = plot_w / points.size
    bar_w = [[slot * 0.62, 3].max, 28].min
    label_every = (points.size / 12.0).ceil
    grid = (0..4).map do |i|
      v = top * i / 4
      y = pad_t + plot_h - (plot_h * i / 4)
      tag.line(x1: pad_l, x2: w - 8, y1: y, y2: y, class: i.zero? ? 'rpt-axis' : 'rpt-gl') +
        content_tag(:text, rpt_money(v, compact: true), x: pad_l - 8, y: y + 4, class: 'rpt-tick', 'text-anchor': 'end')
    end
    bars = points.each_with_index.map do |p, i|
      x = pad_l + slot * i + (slot - bar_w) / 2
      bh = p[:value].positive? ? [plot_h * p[:value] / top, 2].max : 0
      y = pad_t + plot_h - bh
      tip = "#{p[:long]}: #{rpt_money(p[:value])}#{" · #{p[:count]} #{p[:count] == 1 ? 'nota' : 'notas'}" if p.key?(:count)}"
      hit = tag.rect(x: pad_l + slot * i, y: pad_t, width: slot, height: plot_h, class: 'rpt-hit', data: { tip: tip })
      bar = bh.positive? ? tag.path(d: rpt_round_top(x, y, bar_w, bh, [4, bar_w / 2].min), class: 'rpt-bar', style: "--i: #{i}") : ''.html_safe
      label = (i % label_every).zero? ? content_tag(:text, p[:short], x: x + bar_w / 2, y: h - 8, class: 'rpt-tick', 'text-anchor': 'middle') : ''.html_safe
      content_tag(:g, bar + label + hit, class: 'rpt-col')
    end
    svg = content_tag(:svg, safe_join(grid + bars), viewBox: "0 0 #{w.to_i} #{h.to_i}", class: 'rpt-svg', role: 'img', 'aria-label': title)
    svg + rpt_table(%w[Período Faturamento] + (points.first.key?(:count) ? ['Notas'] : []),
                    points.map { |p| [p[:long], rpt_money(p[:value])] + (p.key?(:count) ? [p[:count]] : []) })
  end

  # Barras deitadas (rankings). items: [{ label:, value:, share:, count:/pieces: }]
  def rpt_bars(items, empty: 'Sem venda no período.', extra: nil)
    return content_tag(:p, empty, class: 'rpt-empty') if items.empty?

    max = items.map { |x| x[:value] }.max.to_f
    rows = items.each_with_index.map do |x, i|
      pct = max.positive? ? (x[:value] / max * 100).round(2) : 0
      note = extra ? extra.call(x) : nil
      content_tag(:li, class: 'rpt-row', style: "--i: #{i}", data: { tip: "#{x[:label]}: #{rpt_money(x[:value])} · #{rpt_percent(x[:share])} do total#{" · #{note}" if note}" }) do
        content_tag(:div, safe_join([content_tag(:span, x[:label], class: 'rpt-lbl'), content_tag(:span, rpt_money(x[:value]), class: 'rpt-val')]), class: 'rpt-row-top') +
          content_tag(:div, content_tag(:span, '', class: 'rpt-fill', style: "--w: #{pct}%"), class: 'rpt-track') +
          content_tag(:div, safe_join([rpt_percent(x[:share]), note].compact, ' · '), class: 'rpt-sub')
      end
    end
    content_tag(:ol, safe_join(rows), class: 'rpt-bars stagger')
  end

  # Curva ABC (Pareto): colunas do faturamento de cada modelo, do maior para o menor, na cor da classe, e a linha
  # do acumulado (0 a 100%) com as faixas de 80% e 95%. points: [{ label:, value:, cumulative:, abc: }]
  def rpt_pareto(points, title:, height: 260)
    return content_tag(:p, 'Sem venda no período.', class: 'rpt-empty') if points.empty?

    w = 1100.0
    h = height.to_f
    pad_l = 64.0
    pad_r = 44.0
    pad_b = 18.0
    pad_t = 12.0
    plot_w = w - pad_l - pad_r
    plot_h = h - pad_b - pad_t
    top = rpt_nice_max(points.map { |p| p[:value] }.max.to_f)
    slot = plot_w / points.size
    bar_w = [[slot * 0.7, 2].max, 26].min
    y_of = ->(share) { pad_t + plot_h - plot_h * share }
    grid = (0..4).map do |i|
      y = pad_t + plot_h - (plot_h * i / 4)
      tag.line(x1: pad_l, x2: w - pad_r, y1: y, y2: y, class: i.zero? ? 'rpt-axis' : 'rpt-gl') +
        content_tag(:text, rpt_money(top * i / 4, compact: true), x: pad_l - 8, y: y + 4, class: 'rpt-tick', 'text-anchor': 'end') +
        content_tag(:text, "#{i * 25}%", x: w - pad_r + 6, y: y + 4, class: 'rpt-tick')
    end
    bands = [[0.8, 'A | B'], [0.95, 'B | C']].map do |share, label|
      y = y_of.call(share)
      tag.line(x1: pad_l, x2: w - pad_r, y1: y, y2: y, class: 'rpt-band') + content_tag(:text, label, x: pad_l + 6, y: y - 4, class: 'rpt-tick rpt-band-lbl')
    end
    bars = points.each_with_index.map do |p, i|
      x = pad_l + slot * i + (slot - bar_w) / 2
      bh = [plot_h * p[:value] / top, 2].max
      tip = "#{p[:label]} · classe #{p[:abc]}: #{rpt_money(p[:value])} · acumulado #{rpt_percent(p[:cumulative])}"
      content_tag(:g, class: 'rpt-col') do
        tag.path(d: rpt_round_top(x, pad_t + plot_h - bh, bar_w, bh, [3, bar_w / 2].min), class: "rpt-bar rpt-abc-#{p[:abc].downcase}", style: "--i: #{i}") +
          tag.rect(x: pad_l + slot * i, y: pad_t, width: slot, height: plot_h, class: 'rpt-hit', data: { tip: tip })
      end
    end
    line = points.each_with_index.map { |p, i| "#{(pad_l + slot * i + slot / 2).round(1)},#{y_of.call(p[:cumulative]).round(1)}" }.join(' ')
    svg = content_tag(:svg, safe_join(grid + bands + bars + [tag.polyline(points: line, class: 'rpt-cum')]),
                      viewBox: "0 0 #{w.to_i} #{h.to_i}", class: 'rpt-svg rpt-pareto', role: 'img', 'aria-label': title)
    svg + rpt_table(%w[Modelo Classe Faturamento Acumulado], points.map { |p| [p[:label], p[:abc], rpt_money(p[:value]), rpt_percent(p[:cumulative])] })
  end

  def rpt_table(headers, rows)
    content_tag(:details, class: 'rpt-table') do
      content_tag(:summary, safe_join([content_tag(:i, '', class: 'fas fa-table'), 'Ver tabela'])) +
        content_tag(:div, class: 'table-responsive') do
          content_tag(:table, class: 'table') do
            content_tag(:thead, content_tag(:tr, safe_join(headers.map { |h| content_tag(:th, h) }))) +
              content_tag(:tbody, safe_join(rows.map { |r| content_tag(:tr, safe_join(r.map { |c| content_tag(:td, c) })) }))
          end
        end
    end
  end

  # Topo "redondo" do eixo: 1, 2, 2,5 ou 5 × 10^n acima do máximo.
  def rpt_nice_max(max)
    exp = 10**Math.log10(max).floor
    [1, 2, 2.5, 5, 10].map { |m| m * exp }.find { |v| v >= max }
  end

  def rpt_round_top(x, y, w, h, r)
    r = [r, h].min
    "M#{x},#{y + h} V#{y + r} Q#{x},#{y} #{x + r},#{y} H#{x + w - r} Q#{x + w},#{y} #{x + w},#{y + r} V#{y + h} Z"
  end

  # Tabela completa da análise de produtos (um modelo por linha), filtrável por classe, situação e busca.
  def rpt_products_table(report)
    rows = report.models.map do |m|
      { modelo: m[:model], abc: m[:abc], st: m[:status], motivo: m[:reason].to_s, fat: m[:revenue], pecas: m[:pieces],
        share: m[:share].positive? ? rpt_percent(m[:share]) : '—', acum: m[:cumulative] ? rpt_percent(m[:cumulative]) : '—',
        tend: m[:trend] ? "#{m[:trend].positive? ? '▲' : (m[:trend].negative? ? '▼' : '=')} #{rpt_percent(m[:trend].abs, precision: 0)}" : '—',
        preco: m[:avg_price].to_f, margem: m[:margin] ? rpt_percent(m[:margin], precision: 0) : '—',
        varejo: m[:retail_ratio] ? rpt_percent(m[:retail_ratio], precision: 0) : '—',
        ultima: m[:last_sale], dias: m[:days_since] || '—', pedidos: m[:orders], clientes: m[:clients],
        entrou: m[:received] || '—', giro: m[:sell_through] ? rpt_percent(m[:sell_through], precision: 0) : '—' }
    end
    status_map = Reports::WholesaleProducts::STATUSES.transform_values { |v| v }
    HoneyTable.new(params, rows: rows, unit: 'modelos', unit1: 'modelo', page_size: 25, sort: { k: :fat, dir: -1 },
      cols: [
        { k: :modelo, label: 'Modelo', main: true, sub: :motivo, sort: true },
        { k: :motivo, label: 'Por quê', hide: true },
        { k: :abc, label: 'Curva', t: :status, map: Reports::WholesaleProducts::CLASSES, sort: true },
        { k: :st, label: 'Situação', t: :status, map: status_map },
        { k: :fat, label: 'Faturamento', t: :money, sort: true },
        { k: :pecas, label: 'Peças', t: :qty, sort: true },
        { k: :share, label: '% do total' },
        { k: :acum, label: 'Acumulado', hide: true },
        { k: :tend, label: 'Tendência (peças)' },
        { k: :preco, label: 'Preço médio', t: :money, sort: true },
        { k: :margem, label: 'Margem s/ custo' },
        { k: :varejo, label: '% do varejo', hide: true },
        { k: :ultima, label: 'Última venda', t: :d, sort: true },
        { k: :dias, label: 'Dias sem venda', sort: true },
        { k: :pedidos, label: 'Pedidos', t: :qty, hide: true },
        { k: :clientes, label: 'Clientes', t: :qty, sort: true },
        { k: :entrou, label: 'Entrou no Log02', hide: true },
        { k: :giro, label: 'Giro da entrada', hide: true }
      ],
      filters: [
        { id: :q, type: :search, label: 'Buscar', ph: 'Modelo…', cols: %i[modelo] },
        { id: :abc, type: :select, label: 'Curva', col: :abc, all: 'Todas' },
        { id: :st, type: :select, label: 'Situação', col: :st, all: 'Todas' }
      ])
  end

end
