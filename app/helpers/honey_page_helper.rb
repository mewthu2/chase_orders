# HTML do motor de páginas do protótipo (kpisHTML, tableHTML, bodyHTML, cellInner, openDetail),
# alimentado por um HoneyTable. Cada tela só descreve colunas, filtros e indicadores.
module HoneyPageHelper
  # URL da tela atual com parâmetros trocados (nil remove).
  def hc_pg_url(changes = {})
    query = request.query_parameters.merge(changes.transform_keys(&:to_s)).compact_blank
    query.empty? ? request.path : "#{request.path}?#{query.to_query}"
  end

  # Indicadores ligados à tabela: clicar filtra (kpi=i) e clicar de novo tira o filtro.
  def hc_pg_kpis(table)
    items = table.kpis
    content_tag(:div, class: 'kpi-grid stagger pg-kpis', style: "--cols: #{[items.size, 4].min}") do
      safe_join(items.each_with_index.map do |kpi, i|
        value = table.kpi_value(kpi)
        numeric = value.is_a?(Numeric)
        clickable = table.kpi_clickable?(kpi)
        active = clickable && table.kpi_index == i
        card = content_tag(:div, class: "stat-card#{' is-zero' if numeric && value.zero?}", style: "--tone: #{hc_tone(kpi[:tone] || 'blue')}") do
          content_tag(:span, '', class: 'tone-bar') +
            content_tag(:div, content_tag(:span, kpi[:label], class: 'ticket-stat__label') + content_tag(:span, content_tag(:i, '', class: kpi[:icon] || 'fas fa-chart-simple'), class: 'stat-ic'), class: 'stat-top') +
            content_tag(:div, numeric ? number_with_delimiter(value, delimiter: '.') : value, class: "stat-value#{' is-text' unless numeric}", data: { count: (value if numeric && value == value.to_i) }) +
            content_tag(:div, content_tag(:span, kpi[:help]) + (clickable ? content_tag(:span, safe_join([active ? 'Filtrando ' : 'Ver ', content_tag(:i, '', class: 'fas fa-arrow-right')]), class: 'go') : ''.html_safe), class: 'stat-help')
        end
        if clickable
          link_to(card, hc_pg_url(table.param_name(:kpi) => (active ? nil : i), table.param_name(:page) => nil, (table.tabs ? table.tab_param : 'tab') => nil),
                  class: "pg-kpi spot#{' is-active' if active}", style: "--i: #{i}", data: { tip: "#{kpi[:label]}: #{kpi[:help]} Clique para filtrar a lista." })
        else
          content_tag(:div, card, class: 'pg-kpi is-static spot', style: "--i: #{i}")
        end
      end)
    end
  end

  # Bloco de cartões (cardsHTML do protótipo). items: [{ icon:, title:, sub:, status: [rótulo, tom], tone:,
  # meta: [[ícone, texto]], tags: [...], actions: html }]
  def hc_pg_cards(title:, items:, icon: 'fas fa-grip', meta: nil, cols: 3)
    head = content_tag(:div, content_tag(:h3, content_tag(:i, '', class: icon) + title) + (meta ? content_tag(:span, meta) : ''.html_safe), class: 'pg-sec-h')
    cards = content_tag(:div, class: 'pg-cards stagger', style: "--cols: #{cols}") do
      safe_join(items.each_with_index.map do |x, i|
        content_tag(:article, class: 'pg-cardi spot', style: "--i: #{i}; --tone: #{hc_tone(x[:tone] || 'blue')}") do
          header = content_tag(:header) do
            content_tag(:span, content_tag(:i, '', class: x[:icon] || 'fas fa-folder'), class: 'ci-ic') +
              content_tag(:div, content_tag(:h4, x[:title]) + (x[:sub] ? content_tag(:p, x[:sub]) : ''.html_safe)) +
              (x[:status] ? content_tag(:span, x[:status][0], class: 'ticket-status', style: "--c: #{hc_tone(x[:status][1])}") : ''.html_safe)
          end
          meta_list = Array(x[:meta]).any? ? content_tag(:ul, safe_join(x[:meta].map { |ic, text| content_tag(:li, content_tag(:i, '', class: ic) + content_tag(:span, text)) }), class: 'ci-meta') : ''.html_safe
          tags = Array(x[:tags]).any? ? content_tag(:div, safe_join(x[:tags].map { |t| content_tag(:span, t, class: 'pg-tag') }), class: 'ci-tags') : ''.html_safe
          header + meta_list + tags + (x[:actions].present? ? content_tag(:footer, x[:actions]) : ''.html_safe)
        end
      end)
    end
    head + cards
  end

  # Barras horizontais (barsHTML do protótipo). items: [{ label:, sub:, value:, tone: }]; fmt: :money.
  def hc_pg_bars(title:, items:, icon: 'fas fa-chart-bar', sub: nil, fmt: nil, unit: nil)
    max = [items.map { |x| x[:value].to_f }.max.to_f, 1].max
    fmt_value = ->(v) { fmt == :money ? number_to_currency(v, unit: 'R$ ', separator: ',', delimiter: '.') : number_with_delimiter(v, delimiter: '.') }
    content_tag(:div, class: 'panel pg-card pg-bars') do
      content_tag(:h3, content_tag(:i, '', class: icon) + title) + (sub ? content_tag(:p, sub, class: 'pg-p', style: 'margin-bottom: 12px') : ''.html_safe) +
        content_tag(:div, class: 'pg-bar-list') do
          safe_join(items.each_with_index.map do |x, i|
            content_tag(:div, class: 'pg-bar-row', style: "--w: #{[(x[:value].to_f / max) * 100, 2].max.round(1)}%; --i: #{i}; --tone: #{hc_tone(x[:tone] || 'blue')}") do
              content_tag(:span, content_tag(:b, x[:label]) + (x[:sub] ? content_tag(:small, x[:sub]) : ''.html_safe), class: 'pg-bar-l') +
                content_tag(:span, content_tag(:i, ''), class: 'pg-bar-t') +
                content_tag(:span, fmt_value.call(x[:value]) + (unit ? content_tag(:small, " #{unit}") : ''.html_safe), class: 'pg-bar-v')
            end
          end)
        end
    end
  end

  # Cartão da tabela inteiro. Opções:
  #   title:, icon:, meta:, tools: (html), locs: (nil | :all | [nomes]), empty: { title:, text:, cta: html },
  #   link: ->(row) { url do item principal }, actions: ->(row) { html das ações }, detail: { title: ->(row), note:, fields: [[rótulo, k]] }
  # select: ->(row) { { id:, tiny_order_id: } } liga uma caixa de seleção em cada linha (classe row-select-checkbox,
  # usada pelo JS de execução em lote); bulk: html da barra de ação em lote (pg-bulk).
  def hc_pg_table(table, title:, icon: nil, meta: nil, tools: nil, locs: nil, empty: {}, link: nil, actions: nil, detail: nil, foot: nil, select: nil, bulk: nil)
    content_tag(:section, class: 'table-card pg-card', id: "pgt-#{table.id}") do
      head = content_tag(:div, class: 'table-toolbar') do
        content_tag(:div) do
          content_tag(:h3, safe_join([(content_tag(:i, '', class: icon, style: 'color: var(--text-3); margin-right: 8px') if icon), title].compact)) +
            (meta ? content_tag(:div, meta, class: 'meta') : ''.html_safe)
        end + content_tag(:div, tools, class: 'pg-tools')
      end
      head + hc_pg_tabs(table) + content_tag(:div, hc_pg_filters(table), class: 'pg-fwrap') +
        content_tag(:div, hc_pg_body(table, locs: locs, empty: empty, link: link, actions: actions, detail: detail, foot: foot, select: select, bulk: bulk), class: 'pg-body')
    end
  end

  def hc_pg_tabs(table)
    return ''.html_safe unless table.tabs

    current = table.tab_index.to_i
    content_tag(:div, class: "scope-tabs pg-tabs#{' pg-tabs--scroll' if table.tabs[:items].size > 5}", role: 'tablist') do
      safe_join(table.tabs[:items].each_with_index.map do |tab, i|
        link_to(hc_pg_url(table.tab_param => (i.zero? ? nil : tab[0]), table.param_name(:page) => nil), class: "scope-tab#{' is-active' if current == i}", role: 'tab', 'aria-selected': current == i) do
          safe_join([tab[1], content_tag(:span, table.tab_count(tab), class: 'count')])
        end
      end)
    end
  end

  def hc_pg_filters(table)
    return ''.html_safe if table.filters.empty?

    own = table.filters.map { |f| table.param_name(f[:id]) } + [table.param_name(:page)]
    head = content_tag(:div, class: 'filters-head') do
      content_tag(:h3, content_tag(:i, '', class: 'fas fa-sliders-h') + 'Filtrar') +
        (table.filtered? ? link_to(safe_join([content_tag(:i, '', class: 'fas fa-eraser'), 'Limpar filtros']), hc_pg_clear_url(table), class: 'btn btn-ghost btn-sm') : ''.html_safe)
    end
    form = form_with(url: request.path, method: :get, local: true, class: 'ticket-filters pg-filters', html: { style: "--n: #{[table.filters.size, 4].min}" }) do
      hidden = request.query_parameters.except(*own).map { |k, v| hidden_field_tag(k, v, id: nil) }
      safe_join(hidden + table.filters.map { |f| hc_pg_filter_field(table, f) })
    end
    head + form
  end

  def hc_pg_filter_field(table, filter)
    name = table.param_name(filter[:id])
    value = table.filter_value(filter)
    label = content_tag(:label, safe_join([filter[:label], (content_tag(:span, 'i', class: 'info-dot', tabindex: 0, data: { tip: filter[:tip] }) if filter[:tip])].compact), class: 'field-label', for: "pgf-#{table.id}-#{filter[:id]}")
    if filter[:type] == :search
      content_tag(:div, class: 'filter-field pg-ff-search') do
        label + content_tag(:div, text_field_tag(name, value, id: "pgf-#{table.id}-#{filter[:id]}", class: "field-input#{' is-set' if value}", placeholder: filter[:ph] || 'Buscar…', autocomplete: 'off', onchange: 'this.form.requestSubmit()'), class: 'select-wrap pg-search')
      end
    else
      all = filter[:all] || (filter[:type] == :period ? 'Todo o período' : 'Todos')
      options = [[all, '']] + table.filter_options(filter).map { |v, l| [l, v] }
      content_tag(:div, class: 'filter-field') do
        label + content_tag(:div, select_tag(name, options_for_select(options, value.to_s), id: "pgf-#{table.id}-#{filter[:id]}", class: "field-input#{' is-set' if value}", onchange: 'this.form.requestSubmit()'), class: 'select-wrap')
      end
    end
  end

  def hc_pg_clear_url(table, only = nil)
    keys = only ? [table.param_name(only)] : (table.filters.map { |f| table.param_name(f[:id]) } + [table.param_name(:kpi), (table.tab_param if table.tabs)].compact)
    hc_pg_url((keys + [table.param_name(:page)]).index_with { nil })
  end

  def hc_pg_body(table, locs:, empty:, link:, actions:, detail:, foot:, select: nil, bulk: nil)
    rows = table.page_rows
    chips = table.filters.filter_map do |f|
      value = table.filter_value(f) or next
      text = f[:type] == :search ? "“#{value}”" : (table.filter_options(f).find { |v, _| v.to_s == value.to_s }&.last || value)
      hc_pg_chip("#{f[:label]}: #{text}", hc_pg_clear_url(table, f[:id]))
    end
    chips << hc_pg_chip(table.kpis[table.kpi_index][:label], hc_pg_clear_url(table, :kpi)) if table.kpi_index && table.kpis[table.kpi_index]
    status = table.status_col
    legend = status ? content_tag(:div, class: 'legend') do
      content_tag(:span, 'Situação:', style: 'color: var(--text-4)') +
        safe_join((status[:map] || {}).values.uniq(&:first).map { |label, tone, help| content_tag(:span, content_tag(:span, '', class: 'dot', style: "color: #{hc_tone(tone)}") + label, class: 'lg', data: { tip: "#{label}: #{help}" }) })
    end : ''.html_safe
    loc_chip = if locs == :all
                 content_tag(:span, content_tag(:i, '', class: 'fas fa-location-dot') + 'Todas as lojas', class: 'filter-chip is-loc', data: { tip: 'Seu perfil enxerga todas as lojas.' })
               elsif locs
                 content_tag(:span, content_tag(:i, '', class: 'fas fa-location-dot') + "Só suas lojas: #{locs.presence&.join(', ') || 'nenhuma'}", class: 'filter-chip is-loc',
                                    data: { tip: 'Seu perfil só enxerga estas lojas. Quem muda isso é o administrador, em Adm › Perfis e Permissões.' })
               end
    unit = table.total == 1 && table.unit1 ? table.unit1 : table.unit
    head = content_tag(:div, class: 'active-filters') do
      safe_join([content_tag(:span, "Mostrando #{number_with_delimiter(table.total, delimiter: '.')} #{unit}#{' (filtrado)' if table.filtered?}:"), loc_chip, *chips, legend].compact)
    end

    return head + hc_pg_empty(table, empty) if rows.empty?

    has_actions = actions || detail
    ths = table.visible_cols.map do |c|
      content_tag(:th, class: ('is-r' if %i[money qty].include?(c[:t]))) do
        if c[:sort]
          s = table.sort
          on = s && s[:k] == c[:k]
          icon = on ? (s[:dir] == -1 ? 'fa-sort-down' : 'fa-sort-up') : 'fa-sort'
          link_to(safe_join([c[:label], content_tag(:i, '', class: "fas #{icon}")]),
                  hc_pg_url(table.param_name(:sort) => c[:k], table.param_name(:dir) => (on && s[:dir] != -1 ? 'desc' : 'asc'), table.param_name(:page) => nil), class: 'pg-th')
        else
          c[:label]
        end
      end
    end
    ths << content_tag(:th, 'Ações', style: 'text-align: right') if has_actions
    ths.unshift(content_tag(:th, check_box_tag(nil, '1', false, id: 'selectAllCheckbox', class: 'pg-cb', 'aria-label': 'Selecionar todos'), class: 'pg-chk')) if select
    trs = rows.each_with_index.map do |row, i|
      content_tag(:tr, style: "--i: #{i}", data: { pg_row: row[:id] }) do
        detail_id = "pgd-#{table.id}-#{row[:id] || i}"
        tds = table.visible_cols.map { |c| hc_pg_td(table, c, row, link, (detail_id if detail)) }
        if select
          data = select.call(row)
          tds.unshift(content_tag(:td, check_box_tag(nil, '1', false, class: 'row-select-checkbox pg-cb', data: data.transform_keys { |k| k.to_s.tr('_', '-') }, 'aria-label': "Selecionar #{row[:id]}"), class: 'pg-chk', data: { label: '' }))
        end
        if has_actions
          view = detail ? content_tag(:button, content_tag(:i, '', class: 'fas fa-eye'), type: 'button', class: 'action-btn', data: { pg_detail: detail_id, tip: detail[:tip] || 'Ver' }, 'aria-label': detail[:tip] || 'Ver') : ''.html_safe
          acts = actions ? actions.call(row) : ''.html_safe
          tds << content_tag(:td, view + acts + (detail ? hc_pg_detail(table, row, detail, detail_id, acts) : ''.html_safe), class: 'td-actions', style: 'text-align: right', data: { label: '' })
        end
        safe_join(tds)
      end
    end
    footer = content_tag(:div, class: 'table-footer') do
      content_tag(:span, "Mostrando #{table.from}–#{table.from + rows.size - 1} de #{number_with_delimiter(table.total, delimiter: '.')}#{" · #{foot}" if foot}") + hc_pg_pager(table)
    end
    head + (bulk || ''.html_safe) + content_tag(:div, content_tag(:table, content_tag(:thead, content_tag(:tr, safe_join(ths))) + content_tag(:tbody, safe_join(trs), class: 'stagger'), class: 'orders-table pg-tbl'), class: 'table-responsive') + footer
  end

  def hc_pg_chip(text, clear_url)
    content_tag(:span, safe_join([text, link_to(content_tag(:i, '', class: 'fas fa-times'), clear_url, class: 'chip-x', 'aria-label': 'Remover filtro')]), class: 'filter-chip')
  end

  def hc_pg_empty(table, empty)
    if table.filtered?
      hc_empty('Nada com esses filtros', 'Tente outra opção ou limpe os filtros para ver tudo de novo.',
               cta: link_to(safe_join([content_tag(:i, '', class: 'fas fa-eraser'), 'Limpar filtros']), hc_pg_clear_url(table), class: 'btn btn-secondary'))
    else
      hc_empty(empty[:title] || 'Nada por aqui ainda', empty[:text] || 'Quando houver registros, eles aparecem aqui.', cta: empty[:cta])
    end
  end

  # Paginação do protótipo: primeira, última, vizinhas da atual e reticências.
  def hc_pg_pager(table)
    return ''.html_safe if table.pages < 2

    page = table.page
    nums = (1..table.pages).each_with_object([]) do |n, acc|
      if n == 1 || n == table.pages || (n - page).abs <= 1 then acc << n
      elsif acc.last != :gap then acc << :gap
      end
    end
    item = ->(label, n, css = nil) { content_tag(:li, link_to(label, hc_pg_url(table.param_name(:page) => n), class: 'page-link'), class: "page-item #{css}".strip) }
    content_tag(:ul, class: 'pagination') do
      safe_join([
        page == 1 ? content_tag(:li, content_tag(:span, content_tag(:i, '', class: 'fas fa-chevron-left'), class: 'page-link'), class: 'page-item disabled') : item.call(content_tag(:i, '', class: 'fas fa-chevron-left'), page - 1),
        *nums.map { |n| n == :gap ? content_tag(:li, content_tag(:span, '…', class: 'page-link'), class: 'page-item disabled') : item.call(n, n, ('active' if n == page)) },
        page == table.pages ? content_tag(:li, content_tag(:span, content_tag(:i, '', class: 'fas fa-chevron-right'), class: 'page-link'), class: 'page-item disabled') : item.call(content_tag(:i, '', class: 'fas fa-chevron-right'), page + 1)
      ])
    end
  end

  def hc_pg_td(table, col, row, link, detail_id = nil)
    main = col[:k] == table.main_key
    t = col[:t]
    classes = [('title-cell' if main && t == :text), ('num' if t == :num), ('due' if t == :dt), ('is-r' if %i[money qty].include?(t)), col[:cls]].compact.join(' ')
    sub = col[:sub] && (sub_col = table.col(col[:sub])) ? table.cell_text(sub_col, row[col[:sub]]) : nil
    content_tag(:td, class: classes.presence, data: { label: col[:label] }) do
      content_tag(:span, class: 'td-val') do
        url = main && link ? link.call(row) : nil
        inner = hc_pg_cell(table, col, row, url)
        # Sem página própria, o item principal abre o painel "Ver" (como no protótipo).
        inner = link_to(inner, '#', class: 'text-main t', data: { pg_detail: detail_id }) if main && !url && detail_id && %i[text num mono].include?(col[:t])
        inner + (sub.present? && sub != '—' ? content_tag(:span, sub, class: 'cell-sub') : ''.html_safe)
      end
    end
  end

  def hc_pg_cell(table, col, row, url)
    v = row[col[:k]]
    wrap = ->(inner) { url ? link_to(inner, url, class: 'text-main t') : inner }
    case col[:t]
    when :num then wrap.call(content_tag(:span, "#{'#' unless col[:plain]}#{v}", class: 'num'))
    when :mono
      wrap.call(content_tag(:span, v.presence || '—', class: 'mono pg-mono')) +
        (col[:copy] && v.present? ? content_tag(:button, content_tag(:i, '', class: 'far fa-copy'), type: 'button', class: 'pg-copy', data: { pg_copy: v, tip: 'Copiar' }, 'aria-label': 'Copiar') : ''.html_safe)
    when :status
      label, tone, help = table.status_info(col, v)
      content_tag(:span, label, class: 'ticket-status', style: "--c: #{hc_tone(tone)}", data: { tip: (help ? "#{label}: #{help}" : nil) })
    when :person then v.is_a?(Array) ? hc_person(v[0], photo: v[1]) : hc_person(v)
    when :loc
      list = Array(v)
      list.empty? ? content_tag(:span, 'Sem location', class: 'pg-loc is-none') : safe_join(list.map { |name, key| hc_location(name, key: key) })
    when :money then hc_money(v)
    when :qty then hc_qty(v, col[:unit])
    when :dt then hc_dt(v)
    when :d then hc_d(v)
    when :chips then Array(v).any? ? safe_join(Array(v).map { |x| content_tag(:span, x, class: 'pg-tag') }) : content_tag(:span, '—', class: 'pg-dash')
    when :tag then v.present? ? content_tag(:span, v, class: 'pg-tag') : content_tag(:span, '—', class: 'pg-dash')
    when :bool then v ? content_tag(:span, content_tag(:i, '', class: 'fas fa-check'), class: 'pg-yes') : content_tag(:span, '—', class: 'pg-dash')
    when :link
      text, href, tip = Array(v)
      text.present? ? link_to(safe_join([content_tag(:i, '', class: 'fas fa-arrow-up-right-from-square'), text]), href || '#', class: 'pg-ext', target: (href ? '_blank' : nil), rel: 'noopener', data: { tip: tip || 'Abre em outra aba' }) : content_tag(:span, '—', class: 'pg-dash')
    when :progress then hc_progress(v.to_f)
    when :steps then hc_steps(*Array(v))
    when :html then v.to_s.html_safe
    else wrap.call(content_tag(:span, v.presence || '—', class: (url ? nil : 'pg-txt')))
    end
  end

  # Painel "Ver" (gaveta lateral), igual ao openDetail do protótipo. Fica num <template> e o
  # honey_shell.js abre ao clicar no olho.
  def hc_pg_detail(table, row, detail, template_id, actions_html)
    labels = (detail[:fields] || []).to_h { |label, key| [key.to_sym, label] }
    kv = table.cols.reject { |c| c[:t] == :status || c[:nodetail] }.map { |c| [labels[c[:k]] || c[:label], table.cell_text(c, row[c[:k]]).presence || '—'] }
    kv += (detail[:fields] || []).reject { |_, key| table.col(key) }.map { |label, key| [label, row[key.to_sym].presence&.to_s || '—'] }
    status = table.status_col
    st = status && table.status_info(status, row[status[:k]])
    area = hc_area
    title = detail[:title].respond_to?(:call) ? detail[:title].call(row) : detail[:title].to_s
    note = detail[:note].respond_to?(:call) ? detail[:note].call(row) : detail[:note]
    drawer = content_tag(:div, '', class: 'backdrop', data: { close: 'drawer' }) + content_tag(:aside, class: 'drawer is-wide', role: 'dialog', 'aria-label': title) do
      content_tag(:div, class: 'drawer-head') do
        content_tag(:div, content_tag(:i, '', class: nav_current&.dig(:item, :icon) || 'fas fa-circle-info'), class: "page-icon#{' is-area' if area}", style: (nav_area_style(area) if area)) +
          content_tag(:div, content_tag(:h2, title) + content_tag(:p, [area&.dig(:title), nav_current&.dig(:item, :label)].compact.join(' › '))) +
          content_tag(:button, content_tag(:i, '', class: 'fas fa-times'), type: 'button', class: 'icon-btn', data: { close: 'drawer' }, 'aria-label': 'Fechar')
      end +
        content_tag(:div, class: 'drawer-body') do
          safe_join([
            (content_tag(:div, content_tag(:span, st[0], class: 'ticket-status', style: "--c: #{hc_tone(st[1])}") + content_tag(:span, st[2]), class: 'pg-d-st', style: "--c: #{hc_tone(st[1])}") if st),
            (content_tag(:div, content_tag(:i, '', class: 'fas fa-circle-info') + content_tag(:span, note), class: 'pg-fnote') if note.present?),
            content_tag(:section, content_tag(:h4, content_tag(:i, '', class: 'fas fa-circle-info') + 'Dados') +
              content_tag(:dl, safe_join(kv.map { |label, value| content_tag(:div, content_tag(:dt, label) + content_tag(:dd, value)) }), class: 'pg-kv'), class: 'help-sec'),
            (detail[:extra].call(row) if detail[:extra])
          ].compact)
        end +
        content_tag(:div, content_tag(:button, 'Fechar', type: 'button', class: 'btn btn-ghost', data: { close: 'drawer' }) + (detail[:foot] ? detail[:foot].call(row) : ''.html_safe), class: 'drawer-foot')
    end
    # Como texto (script), para as linhas do painel não contarem como linhas da página.
    content_tag(:script, drawer, type: 'text/html', id: template_id)
  end
end
