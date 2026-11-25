# Tabela no padrão do motor de páginas do protótipo Honey.Chase: indicadores, abas, filtros
# (busca, select, período), ordenação, paginação, chips e legenda. Recebe as linhas já
# montadas (hashes) e faz tudo em memória, igual ao protótipo — serve para listas de tamanho
# administrativo (setores, transportadoras, empresas, usuários...). O HTML sai de
# HoneyUiHelper#hc_pg_table.
#
#   HoneyTable.new(params, rows:, cols: [...], filters: [...], kpis: [...], tabs: {...}, sort: {...})
#
# Coluna: { k:, label:, t: :text|:num|:status|:person|:loc|:qty|:money|:dt|:d|:tag|:chips|:bool|:mono|:steps|:html|:progress,
#           sub: <k>, sort: true, map: { valor => [rótulo, tom, ajuda] }, hide: true, nodetail: true, main: true, cls:, unit:, plain: }
# Filtro: { id:, type: :search|:select|:period|:month, label:, col:, cols: [...], options: [[valor, rótulo]], all:, tip:, ph:,
#           server: true (o controller já aplicou; aqui só mostra o campo e o chip) }
#         :month é o mês com setas (como o do Tiny), valor "AAAA-MM" ou "todos"; default: o mês mostrado sem valor na URL.
#         :month e :period também aceitam um intervalo de dias do calendário, valor "AAAA-MM-DD..AAAA-MM-DD".
# Indicador: { label:, icon:, tone:, help:, col:, vals: [...], sum: <k>, count:, text: }
class HoneyTable
  PERIODS = [['1', 'Hoje'], ['7', 'Últimos 7 dias'], ['30', 'Últimos 30 dias'], ['90', 'Últimos 90 dias']].freeze

  attr_reader :id, :cols, :filters, :kpis, :tabs, :page_size, :rows, :unit, :unit1, :params

  def initialize(params, rows:, cols:, id: 'main', filters: [], kpis: [], tabs: nil, sort: nil, page_size: 10, unit: 'registros', unit1: nil)
    @params = params
    @id = id
    @rows = rows
    @cols = cols.compact.map { |c| { t: :text }.merge(c) }
    @default_cols = @cols
    @filters = filters
    @kpis = kpis
    @tabs = tabs
    @default_sort = sort
    @page_size = page_size
    @unit = unit
    @unit1 = unit1
  end

  # ---- estado vindo da URL (a tabela principal usa os nomes simples; as outras, prefixados) ----
  def param_name(name) = id == 'main' ? name.to_s : "#{id}_#{name}"
  def param(name) = params[param_name(name)].presence

  def filter_value(filter) = param(filter[:id])
  def kpi_index = param(:kpi)&.to_i
  # Aba ativa: o valor da aba na URL (tabs[:param], padrão "tab"); nil = primeira aba.
  def tab_param = param_name(tabs&.dig(:param) || :tab)
  def tab_value = params[tab_param].presence
  def tab_index = tabs && tab_value ? tabs[:items].index { |t| t[0].to_s == tab_value.to_s } : nil

  def sort
    key = param(:sort)
    return { k: key.to_sym, dir: param(:dir) == 'desc' ? -1 : 1 } if key && cols.any? { |c| c[:k].to_s == key && c[:sort] }

    @default_sort
  end

  def filtered?
    filters.any? { |f| filter_value(f) } || kpi_index || tab_index.to_i.positive?
  end

  def main_key = @main_key ||= (cols.find { |c| c[:main] } || cols.find { |c| !c[:hide] })[:k]
  def status_col = cols.find { |c| c[:t] == :status }
  def visible_cols = cols.reject { |c| c[:hide] }
  def col(key) = cols.find { |c| c[:k] == key.to_sym }
  def default_visible_cols = @default_cols.reject { |c| c[:hide] }

  # ---- colunas arrumadas pela pessoa (botão Colunas) ----
  # saved = [["coluna", true/false], ...] na ordem escolhida. Coluna que não está no salvo (nova na tela) entra
  # na posição padrão, com a visibilidade padrão; a principal (a do link) nunca some.
  def apply_layout(saved)
    main_key
    saved = Array(saved).to_h { |k, on| [k.to_s, on] }
    return self if saved.empty?

    by_key = @default_cols.index_by { |c| c[:k].to_s }
    ordered = saved.keys.filter_map { |k| by_key[k] }
    @default_cols.each_with_index do |c, i|
      next if ordered.include?(c)

      before = @default_cols[0...i].reverse.find { |prev| ordered.include?(prev) }
      ordered.insert(before ? ordered.index(before) + 1 : 0, c)
    end
    @cols = ordered.map do |c|
      key = c[:k].to_s
      hide = c[:k] == main_key ? false : (saved.key?(key) ? !saved[key] : c[:hide])
      c.merge(hide: hide)
    end
    @customized = true
    self
  end

  def customized? = @customized == true

  # O que o painel Colunas mostra: na ordem atual, se está visível, se é a principal (fixa) e o padrão.
  def layout_items
    defaults = @default_cols.to_h { |c| [c[:k], !c[:hide]] }
    cols.map { |c| { k: c[:k].to_s, label: c[:label].to_s, on: !c[:hide], locked: c[:k] == main_key, default: defaults[c[:k]] } }
  end

  def default_layout = @default_cols.map { |c| [c[:k].to_s, !c[:hide]] }

  # ---- linhas ----
  def matching
    @matching ||= begin
      out = rows
      if tabs && tab_index.to_i.positive? && (tab = tabs[:items][tab_index])
        if tabs[:filter] then out = tabs[:filter].call(out, tab[0].to_s)
        elsif !tab[0].to_s.empty? then out = out.select { |r| match?(r[tabs[:col]], tab[0]) }
        end
      end
      if kpi_index && (kpi = kpis[kpi_index]) && kpi[:col]
        out = out.select { |r| match?(r[kpi[:col]], kpi_vals(kpi).join(',')) }
      end
      filters.each do |f|
        value = filter_value(f) or next
        next if f[:server] # o controller já filtrou

        out = case f[:type]
              when :search then search(out, f, value)
              when :period then out.select { |r| (time = r[f[:col]]).respond_to?(:in_time_zone) && period_range(value).cover?(time.in_time_zone) }
              else out.select { |r| match?(r[f[:col]], value) }
              end
      end
      sorted(out)
    end
  end

  def total = matching.size
  def page = [[param(:page).to_i, 1].max, pages].min
  def pages = [(total.to_f / page_size).ceil, 1].max
  def page_rows = matching.slice((page - 1) * page_size, page_size) || []
  def from = (page - 1) * page_size + 1

  # ---- indicadores ----
  def kpi_vals(kpi) = Array(kpi[:vals] || (kpi.key?(:val) ? [kpi[:val]] : nil)).map(&:to_s)

  def kpi_value(kpi)
    return kpi[:text] if kpi.key?(:text)
    return kpi[:count] if kpi.key?(:count)

    vals = kpi_vals(kpi)
    return rows.size if vals.empty? || !kpi[:col]

    hits = rows.select { |r| match?(r[kpi[:col]], vals.join(',')) }
    kpi[:sum] ? hits.sum { |r| r[kpi[:sum]].to_f }.then { |n| n == n.to_i ? n.to_i : n } : hits.size
  end

  def kpi_clickable?(kpi) = kpi[:col].present? && kpi_vals(kpi).any? && !kpi[:static]

  # tabs[:counts] permite contar fora da lista atual (quando o controller já filtrou pela aba).
  def tab_count(tab)
    if tabs[:counts]
      key = tab[0].to_s
      return tabs[:counts].key?(key) ? tabs[:counts][key].to_i : (key.empty? ? tabs[:counts].values.sum : 0)
    end

    tab[0].to_s.empty? ? rows.size : rows.count { |r| match?(r[tabs[:col]], tab[0]) }
  end

  # ---- textos (busca, chips, detalhe) ----
  def cell_text(col, value)
    case col[:t]
    when :status then status_info(col, value)[0]
    when :loc, :chips then Array(value).map { |v| v.is_a?(Array) ? v[0] : v }.join(', ')
    when :person, :link then Array(value).first.to_s
    when :bool then value ? 'Sim' : 'Não'
    when :money then value.nil? ? '' : format('R$ %.2f', value).tr('.', ',')
    when :dt then value.respond_to?(:strftime) ? value.in_time_zone.strftime('%d/%m/%Y %H:%M') : value.to_s
    when :d then value.respond_to?(:strftime) ? value.strftime('%d/%m/%Y') : value.to_s
    when :html then ActionController::Base.helpers.strip_tags(value.to_s)
    else value.is_a?(Array) ? value.join(', ') : value.to_s
    end
  end

  def status_info(col, value)
    map = col[:map] || {}
    map[value] || map[value.to_s] || map[value.to_s.to_sym] || [value.to_s.humanize, 'gray', nil]
  end

  def filter_options(filter)
    if filter[:type] == :period
      label = self.class.range_label(filter_value(filter))
      base = filter[:options] || PERIODS
      return label ? base + [[filter_value(filter).to_s, label]] : base
    end
    return filter[:options] if filter[:options]
    return [[filter_value(filter).to_s, self.class.month_label(filter_value(filter))]] if filter[:type] == :month

    column = col(filter[:col])
    if column && column[:t] == :status
      (column[:map] || {}).map { |k, v| [k.to_s, v[0]] }
    else
      rows.flat_map { |r| Array(r[filter[:col]]) }.compact.uniq.sort_by(&:to_s).map { |v| [v.to_s, v.to_s] }
    end
  end

  MONTHS = %w[Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro].freeze

  # "2026-11" => "Novembro de 2026"; "todos" => "Todos os meses"; "2026-11-03..2026-11-20" => "03/11/2026 a 20/11/2026".
  def self.month_label(value)
    return 'Todos os meses' if value.to_s == 'todos'
    return range_label(value) if parse_range(value)

    date = parse_month(value) or return value.to_s
    "#{MONTHS[date.month - 1]} de #{date.year}"
  end

  def self.parse_month(value)
    Date.strptime(value.to_s, '%Y-%m') if value.to_s.match?(/\A\d{4}-\d{2}\z/)
  rescue Date::Error
    nil
  end

  RANGE_VALUE = /\A(\d{4}-\d{2}-\d{2})\.\.(\d{4}-\d{2}-\d{2})\z/

  # Intervalo escolhido no calendário: "AAAA-MM-DD..AAAA-MM-DD" => do começo do primeiro dia ao fim do último.
  def self.parse_range(value)
    match = value.to_s.match(RANGE_VALUE) or return nil
    first, last = [Date.iso8601(match[1]), Date.iso8601(match[2])].sort
    first.in_time_zone.beginning_of_day..last.in_time_zone.end_of_day
  rescue Date::Error
    nil
  end

  def self.range_label(value)
    range = parse_range(value) or return nil
    first, last = range.begin.to_date, range.end.to_date
    first == last ? first.strftime('%d/%m/%Y') : "#{first.strftime('%d/%m/%Y')} a #{last.strftime('%d/%m/%Y')}"
  end

  def self.norm(text) = I18n.transliterate(text.to_s).downcase

  private

  def match?(cell, value)
    wanted = value.to_s.split(',')
    Array(cell).any? { |x| wanted.include?((x.is_a?(Array) ? x[1] || x[0] : x).to_s) }
  end

  def search(rows, filter, value)
    tokens = self.class.norm(value).split
    search_cols = (filter[:cols] || default_visible_cols.map { |c| c[:k] }).filter_map { |k| col(k) }
    rows.select do |r|
      hay = self.class.norm(search_cols.map { |c| cell_text(c, r[c[:k]]) }.join(' '))
      tokens.all? { |t| hay.include?(t) }
    end
  end

  def period_start(value)
    days = value.to_i
    days == 1 ? Time.current.beginning_of_day : days.days.ago
  end

  # Período do filtro: o intervalo do calendário ou os últimos N dias.
  def period_range(value)
    self.class.parse_range(value) || (period_start(value)..)
  end

  def sorted(rows)
    s = sort or return rows
    column = col(s[:k]) or return rows
    sorted = rows.sort_by do |r|
      v = r[s[:k]]
      v.is_a?(Numeric) || v.respond_to?(:strftime) ? [0, v.respond_to?(:to_time) ? v.to_time.to_f : v] : [1, self.class.norm(cell_text(column, v))]
    end
    (s[:dir] || 1) == -1 ? sorted.reverse : sorted
  end
end
