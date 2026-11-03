# Peças das telas no padrão do protótipo Honey.Chase (o "motor de páginas"): cabeçalho com a
# área do negócio, indicadores que filtram a lista, cartão da tabela com filtros rotulados,
# linha "Mostrando N" com chips e legenda, células tipadas e rodapé com paginação.
# O HTML gerado é o mesmo do protótipo, para as telas ficarem iguais a ele.
module HoneyUiHelper
  TONES = NavigationHelper::TONES.merge('brand' => '#3aa3ea').freeze
  PERSON_COLORS = %w[#1287d6 #3fb950 #a371f7 #f0883e #e3b341 #f85149 #58a6ff #db61a2].freeze
  LOCATION_COLORS = %w[#58a6ff #f0883e #3fb950 #a371f7 #e3b341 #f85149 #39c5cf #db61a2].freeze
  PERIODS = { '1' => 'Hoje', '7' => 'Últimos 7 dias', '30' => 'Últimos 30 dias', '90' => 'Últimos 90 dias' }.freeze

  def hc_tone(tone)
    TONES.fetch(tone.to_s, tone.to_s.start_with?('#') ? tone.to_s : TONES['gray'])
  end

  # Cabeçalho: ícone e sobrelinha na cor da área da tela atual, título, subtítulo e ações.
  # O botão "Como usar esta tela" abre a ajuda; as ações da tela vêm no bloco.
  def hc_page_header(title, subtitle = nil, icon:, help: true, &actions)
    content_tag(:div, class: 'page-header') do
      left = content_tag(:div, class: 'header-left has-icon') do
        hc_page_icon(icon) + content_tag(:div) do
          hc_page_eyebrow + content_tag(:h1, title, class: 'page-title') + (subtitle.present? ? content_tag(:p, subtitle, class: 'page-subtitle') : ''.html_safe)
        end
      end
      right = content_tag(:div, class: 'header-actions') do
        (help ? hc_help_button : ''.html_safe) + (actions ? capture(&actions) : ''.html_safe)
      end
      left + right
    end
  end

  def hc_area
    nav_current&.dig(:area)
  end

  def hc_page_icon(icon)
    area = hc_area
    content_tag(:div, content_tag(:i, '', class: icon.to_s.gsub(/\s*\bm[es]-\d\b/, '')), class: "page-icon#{' is-area' if area}", style: (area ? nav_area_style(area) : nil))
  end

  def hc_page_eyebrow
    area = hc_area
    return ''.html_safe unless area

    text = [area[:title], nav_current&.dig(:group, :label)].compact.join(' › ')
    content_tag(:div, content_tag(:span, '', class: 'area-dot') + text, class: 'page-eyebrow is-area', style: nav_area_style(area))
  end

  def hc_help_button
    button_tag(type: 'button', class: 'btn btn-secondary', data: { act: 'help' }) { content_tag(:i, '', class: 'fas fa-circle-question') + 'Como usar esta tela' }
  end

  # Indicadores. items: [{ label:, icon:, tone:, value:, help:, url:, active: }]
  # Com url o card filtra a lista ("Ver" / "Filtrando"); o número sobe animado (data-count).
  def hc_kpis(items)
    content_tag(:div, class: 'kpi-grid stagger pg-kpis', style: "--cols: #{[items.size, 4].min}") do
      safe_join(items.each_with_index.map do |item, i|
        numeric = item[:value].is_a?(Numeric)
        card = content_tag(:div, class: "stat-card#{' is-zero' if numeric && item[:value].zero?}", style: "--tone: #{hc_tone(item[:tone])}") do
          content_tag(:span, '', class: 'tone-bar') +
            content_tag(:div, content_tag(:span, item[:label], class: 'ticket-stat__label') + content_tag(:span, content_tag(:i, '', class: item[:icon]), class: 'stat-ic'), class: 'stat-top') +
            content_tag(:div, numeric ? number_with_delimiter(item[:value], delimiter: '.') : item[:value], class: "stat-value#{' is-text' unless numeric}", data: { count: (item[:value] if numeric) }) +
            content_tag(:div, content_tag(:span, item[:help]) + (item[:url] ? content_tag(:span, safe_join([item[:active] ? 'Filtrando ' : 'Ver ', content_tag(:i, '', class: 'fas fa-arrow-right')]), class: 'go') : ''.html_safe), class: 'stat-help')
        end
        if item[:url]
          link_to(card, item[:url], class: "pg-kpi spot#{' is-active' if item[:active]}", style: "--i: #{i}", data: { tip: "#{item[:label]}: #{item[:help]} Clique para filtrar a lista." })
        else
          content_tag(:div, card, class: 'pg-kpi is-static spot', style: "--i: #{i}")
        end
      end)
    end
  end

  # Cartão da tabela: título, descrição, ferramentas à direita e o conteúdo (filtros, lista).
  def hc_table_card(title, icon:, meta: nil, tools: nil, id: nil, &block)
    content_tag(:section, class: 'table-card pg-card', id: id) do
      head = content_tag(:div, class: 'table-toolbar') do
        content_tag(:div) do
          content_tag(:h3, content_tag(:i, '', class: icon, style: 'color: var(--text-3); margin-right: 8px') + title) +
            (meta ? content_tag(:div, meta, class: 'meta') : ''.html_safe)
        end + content_tag(:div, tools, class: 'pg-tools')
      end
      head + capture(&block)
    end
  end

  # Painel "Filtrar": envolve o form GET da tela; cada campo usa hc_filter_field.
  # clear: url da lista sem filtros, mostrada como "Limpar filtros" quando há filtro ativo.
  def hc_filters(url, columns: 4, clear: nil, &block)
    content_tag(:div, class: 'pg-fwrap') do
      head = content_tag(:div, class: 'filters-head') do
        content_tag(:h3, content_tag(:i, '', class: 'fas fa-sliders-h') + 'Filtrar') +
          (clear ? link_to(safe_join([content_tag(:i, '', class: 'fas fa-eraser'), 'Limpar filtros']), clear, class: 'btn btn-ghost btn-sm') : ''.html_safe)
      end
      head + form_with(url: url, method: :get, local: true, class: 'ticket-filters pg-filters', html: { style: "--n: #{[columns, 4].min}" }, &block)
    end
  end

  def hc_filter_field(label, tip: nil, search: false, &block)
    content_tag(:div, class: "filter-field#{' pg-ff-search' if search}") do
      content_tag(:label, safe_join([label, (tip ? content_tag(:span, 'i', class: 'info-dot', tabindex: 0, data: { tip: tip }) : nil)].compact), class: 'field-label') +
        content_tag(:div, capture(&block), class: search ? 'select-wrap pg-search' : 'select-wrap')
    end
  end

  # Select que reenvia o filtro ao mudar.
  def hc_filter_select(name, options, selected, all:)
    select_tag(name, options_for_select([[all, '']] + options, selected), class: "field-input#{' is-set' if selected.present?}", onchange: 'this.form.requestSubmit()')
  end

  # Busca: envia com Enter ou ao sair do campo.
  def hc_filter_search(name, value, placeholder)
    text_field_tag(name, value, class: "field-input#{' is-set' if value.present?}", placeholder: placeholder, autocomplete: 'off',
                                onchange: 'this.form.requestSubmit()')
  end

  def hc_period_options
    PERIODS.map { |k, v| [v, k] }
  end

  # Começo do período escolhido no filtro (nil = todo o período).
  def self.period_start(value)
    days = value.to_i
    return nil unless PERIODS.key?(value.to_s)

    days == 1 ? Time.current.beginning_of_day : days.days.ago.beginning_of_day
  end

  # Linha "Mostrando N itens (filtrado):" + chip das lojas do perfil + chips dos filtros
  # ("Rótulo: valor" com x para limpar) + legenda das situações.
  # chips: [{ label:, value:, clear: }] · legend: [[rótulo, tom, dica]]
  # locs: nil (tela sem loja), :all, ou a lista de nomes das lojas do perfil.
  def hc_active_filters(count, unit, unit1: nil, filtered: false, locs: nil, chips: [], legend: [])
    content_tag(:div, class: 'active-filters') do
      shown = content_tag(:span, "Mostrando #{number_with_delimiter(count, delimiter: '.')} #{count == 1 && unit1 ? unit1 : unit}#{' (filtrado)' if filtered}:")
      loc_chip = if locs == :all
                   content_tag(:span, content_tag(:i, '', class: 'fas fa-location-dot') + 'Todas as lojas', class: 'filter-chip is-loc', data: { tip: 'Seu perfil enxerga todas as lojas.' })
                 elsif locs
                   content_tag(:span, content_tag(:i, '', class: 'fas fa-location-dot') + "Só suas lojas: #{locs.presence&.join(', ') || 'nenhuma'}", class: 'filter-chip is-loc',
                                      data: { tip: 'Seu perfil só enxerga estas lojas. Quem muda isso é o administrador, em Adm › Perfis e Permissões.' })
                 else
                   ''.html_safe
                 end
      chip_tags = chips.map do |chip|
        text = chip[:value] ? "#{chip[:label]}: #{chip[:value]}" : chip[:label]
        content_tag(:span, class: 'filter-chip') do
          safe_join([text, (chip[:clear] ? link_to(content_tag(:i, '', class: 'fas fa-times'), chip[:clear], 'aria-label': 'Remover filtro', class: 'chip-x') : nil)].compact)
        end
      end
      legend_tag = legend.any? ? content_tag(:div, class: 'legend') do
        content_tag(:span, 'Situação:', style: 'color: var(--text-4)') +
          safe_join(legend.map { |label, tone, tip| content_tag(:span, content_tag(:span, '', class: 'dot', style: "color: #{hc_tone(tone)}") + label, class: 'lg', data: { tip: "#{label}: #{tip}" }) })
      end : ''.html_safe
      shown + loc_chip + safe_join(chip_tags) + legend_tag
    end
  end

  # ---- tabela ----

  # Cabeçalho de coluna; com sort: vira botão que ordena (asc → desc) mantendo os filtros.
  def hc_th(label, sort: nil, right: false)
    content_tag(:th, class: ('is-r' if right)) do
      if sort
        current = params[:sort] == sort.to_s
        dir = current && params[:dir] == 'asc' ? 'desc' : 'asc'
        icon = current ? (params[:dir] == 'asc' ? 'fa-sort-up' : 'fa-sort-down') : 'fa-sort'
        link_to(safe_join([label, content_tag(:i, '', class: "fas #{icon}")]), url_for(request.query_parameters.merge('sort' => sort, 'dir' => dir, 'page' => nil).compact), class: 'pg-th')
      else
        label
      end
    end
  end

  # Célula: valor + linha de apoio embaixo (sub). type ajusta a classe como no protótipo.
  def hc_td(label, sub: nil, type: nil, main: false, &block)
    classes = [('title-cell' if main && type.nil?), ('num' if type == :num), ('due' if type == :dt), ('is-r' if %i[qty money].include?(type))].compact.join(' ')
    content_tag(:td, class: classes.presence, data: { label: label }) do
      content_tag(:span, class: 'td-val') do
        capture(&block) + (sub.present? && sub != '—' ? content_tag(:span, sub, class: 'cell-sub') : ''.html_safe)
      end
    end
  end

  def hc_status(label, tone, tip: nil)
    content_tag(:span, label, class: 'ticket-status', style: "--c: #{hc_tone(tone)}", data: { tip: tip ? "#{label}: #{tip}" : nil })
  end

  def hc_location(name, key: nil)
    return content_tag(:span, 'Sem location', class: 'pg-loc is-none') if name.blank?

    color = LOCATION_COLORS[(key || name).to_s.sum % LOCATION_COLORS.size]
    content_tag(:span, content_tag(:i, '', style: "background: #{color}") + name, class: 'pg-loc')
  end

  # Pessoa com avatar: a foto, quando houver, senão as iniciais numa bolinha colorida.
  def hc_person(name, photo: nil)
    return content_tag(:span, '—', class: 'pg-dash') if name.blank?

    initials = name.to_s.split.values_at(0, -1).compact.uniq.map { |p| p[0] }.join.upcase
    color = PERSON_COLORS[name.to_s.sum % PERSON_COLORS.size]
    face = photo ? image_tag(photo, alt: "Foto de #{name}") : initials
    content_tag(:span, content_tag(:span, face, class: "avatar sm#{' has-photo' if photo}", style: "--c: #{color}") + name, class: 'person')
  end

  def hc_qty(value, unit = nil)
    content_tag(:b, number_with_delimiter(value.to_i, delimiter: '.'), class: 'pg-qty') + (unit ? content_tag(:small, " #{unit}", class: 'pg-unit') : ''.html_safe)
  end

  def hc_money(value)
    content_tag(:span, number_to_currency(value || 0, unit: 'R$ ', separator: ',', delimiter: '.'), class: 'pg-money')
  end

  def hc_ago(time)
    ref = time.respond_to?(:hour) ? time : time.in_time_zone
    return 'agora' if (Time.current - ref).abs < 60

    ref > Time.current ? "em #{time_ago_in_words(ref)}" : "há #{time_ago_in_words(ref)}"
  end

  # Data simples (coluna "d" do protótipo).
  def hc_d(date)
    return content_tag(:span, '—', class: 'pg-dash') if date.blank?

    content_tag(:span, date.strftime('%d/%m/%Y'), class: 'pg-d0')
  end

  # Data e hora com o "há quanto tempo" (coluna "dt" do protótipo).
  def hc_dt(time)
    return content_tag(:span, '—', class: 'pg-dash') if time.blank?

    time = time.in_time_zone
    content_tag(:b, time.strftime('%d/%m/%Y'), class: 'pg-d1') + content_tag(:small, "#{time.strftime('%H:%M')} · #{hc_ago(time)}")
  end

  # Data com o "há quanto tempo" embaixo (sem hora).
  def hc_date(time, with_time: false)
    return hc_dt(time) if with_time && time.respond_to?(:hour)
    return content_tag(:span, '—', class: 'pg-dash') if time.blank?

    content_tag(:b, time.strftime('%d/%m/%Y'), class: 'pg-d1') + content_tag(:small, hc_ago(time))
  end

  def hc_num(id)
    content_tag(:span, "##{id}", class: 'num')
  end

  # Bolinhas das etapas (1 a total); error marca a etapa atual em vermelho.
  def hc_steps(at, total, error: false)
    dots = (0...total).map do |i|
      css = if i < at - (error ? 1 : 0) then 'on'
            elsif i == at - 1 && error then 'bad'
            elsif i == at - 1 then 'cur'
            end
      content_tag(:i, '', class: css)
    end
    content_tag(:span, safe_join(dots), class: "pg-dots#{' is-err' if error}", data: { tip: "Etapa #{at} de #{total}#{' (com erro)' if error}" })
  end

  # Barra de progresso com a porcentagem ao lado.
  def hc_progress(pct, tone: nil)
    pct = pct.to_f.clamp(0, 100)
    bar = content_tag(:i, '', style: "width: #{pct.round(1)}%#{"; background: #{hc_tone(tone)}" if tone}")
    content_tag(:span, bar, class: 'pg-prog', data: { tip: "#{pct.round}%" }) + content_tag(:b, "#{pct.round}%", class: 'pg-qty')
  end

  # Estado vazio no padrão do protótipo (ilustração animada, texto e chamada).
  def hc_empty(title, text, cta: nil)
    content_tag(:div, class: 'ticket-empty pg-empty') do
      art = content_tag(:div, class: 'empty-art') do
        raw('<svg viewBox="0 0 168 128" fill="none" aria-hidden="true"><rect x="26" y="34" width="116" height="78" rx="14" fill="rgba(255,255,255,.03)" stroke="rgba(255,255,255,.14)"/><rect x="42" y="52" width="60" height="8" rx="4" fill="rgba(124,196,244,.45)"/><rect x="42" y="68" width="84" height="6" rx="3" fill="rgba(255,255,255,.12)"/><rect x="42" y="82" width="70" height="6" rx="3" fill="rgba(255,255,255,.08)"/><circle cx="128" cy="34" r="16" fill="rgba(18,135,214,.18)" stroke="rgba(58,163,234,.5)"/><path d="M121 34l5 5 9-10" stroke="#7cc4f4" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>') +
          content_tag(:span, '', class: 'spark', style: 'left: 12px; top: 18px') + content_tag(:span, '', class: 'spark', style: 'right: 8px; bottom: 26px; animation-delay: -1s')
      end
      art + content_tag(:h3, title) + content_tag(:p, text) + (cta ? content_tag(:div, cta, class: 'empty-actions') : ''.html_safe)
    end
  end

  # Vazio por causa dos filtros: o mesmo texto do protótipo, com "Limpar filtros".
  def hc_empty_filtered(clear_url)
    hc_empty('Nada com esses filtros', 'Tente outra opção ou limpe os filtros para ver tudo de novo.',
             cta: link_to(safe_join([content_tag(:i, '', class: 'fas fa-eraser'), 'Limpar filtros']), clear_url, class: 'btn btn-secondary'))
  end

  # Rodapé da tabela: "Mostrando 1–8 de 16" + paginação.
  def hc_table_footer(collection, param_name: :page)
    return ''.html_safe unless collection.respond_to?(:total_entries)

    from = collection.offset + 1
    to = collection.offset + collection.size
    content_tag(:div, class: 'table-footer') do
      content_tag(:span, "Mostrando #{from}–#{to} de #{number_with_delimiter(collection.total_entries, delimiter: '.')}") +
        (will_paginate(collection, param_name: param_name, renderer: WillPaginate::ActionView::BootstrapLinkRenderer, inner_window: 1, outer_window: 0,
                                   previous_label: content_tag(:i, '', class: 'fas fa-chevron-left'), next_label: content_tag(:i, '', class: 'fas fa-chevron-right')) || ''.html_safe)
    end
  end

  # Ação da linha (ícone com dica). Com method vira um form (button_to). confirm abre a janela de
  # confirmação do protótipo: texto simples ou { title:, text:, ok: }.
  def hc_row_action(icon, tip, url, danger: false, method: nil, confirm: nil, params: {})
    classes = "action-btn#{' action-btn--danger' if danger}"
    if method
      button_to url, method: method, params: params, class: classes, data: { tip: tip }, 'aria-label': tip,
                     form: { style: 'display: inline', data: { hc_confirm: hc_confirm_json(confirm, tip, icon, danger) } } do
        content_tag(:i, '', class: icon)
      end
    else
      link_to content_tag(:i, '', class: icon), url, class: classes, data: { tip: tip }, 'aria-label': tip
    end
  end

  def hc_confirm_json(confirm, tip, icon, danger)
    return nil unless confirm

    opts = confirm.is_a?(Hash) ? confirm : { title: confirm.to_s.split(/(?<=\?)\s/, 2).first, text: confirm.to_s.split(/(?<=\?)\s/, 2).second.to_s }
    { ok: tip, icon: icon, danger: danger }.merge(opts).to_json
  end
end
