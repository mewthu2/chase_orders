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
end
