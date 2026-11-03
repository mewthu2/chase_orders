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
# Filtro: { id:, type: :search|:select|:period, label:, col:, cols: [...], options: [[valor, rótulo]], all:, tip:, ph:,
#           server: true (o controller já aplicou; aqui só mostra o campo e o chip) }
# Indicador: { label:, icon:, tone:, help:, col:, vals: [...], sum: <k>, count:, text: }
class HoneyTable
  PERIODS = [['1', 'Hoje'], ['7', 'Últimos 7 dias'], ['30', 'Últimos 30 dias'], ['90', 'Últimos 90 dias']].freeze

  attr_reader :id, :cols, :filters, :kpis, :tabs, :page_size, :rows, :unit, :unit1, :params

  def initialize(params, rows:, cols:, id: 'main', filters: [], kpis: [], tabs: nil, sort: nil, page_size: 10, unit: 'registros', unit1: nil)
    @params = params
    @id = id
    @rows = rows
    @cols = cols.map { |c| { t: :text }.merge(c) }
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

  def main_key = (cols.find { |c| c[:main] } || cols.find { |c| !c[:hide] })[:k]
  def status_col = cols.find { |c| c[:t] == :status }
  def visible_cols = cols.reject { |c| c[:hide] }
  def col(key) = cols.find { |c| c[:k] == key.to_sym }

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
              when :period then out.select { |r| (time = r[f[:col]]) && time >= period_start(value) }
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
    return filter[:options] if filter[:options]
    return PERIODS if filter[:type] == :period

    column = col(filter[:col])
    if column && column[:t] == :status
      (column[:map] || {}).map { |k, v| [k.to_s, v[0]] }
    else
      rows.flat_map { |r| Array(r[filter[:col]]) }.compact.uniq.sort_by(&:to_s).map { |v| [v.to_s, v.to_s] }
    end
  end

  def self.norm(text) = I18n.transliterate(text.to_s).downcase

  private

  def match?(cell, value)
    wanted = value.to_s.split(',')
    Array(cell).any? { |x| wanted.include?((x.is_a?(Array) ? x[1] || x[0] : x).to_s) }
  end

  def search(rows, filter, value)
    tokens = self.class.norm(value).split
    search_cols = (filter[:cols] || visible_cols.map { |c| c[:k] }).filter_map { |k| col(k) }
    rows.select do |r|
      hay = self.class.norm(search_cols.map { |c| cell_text(c, r[c[:k]]) }.join(' '))
      tokens.all? { |t| hay.include?(t) }
    end
  end

  def period_start(value)
    days = value.to_i
    days == 1 ? Time.current.beginning_of_day : days.days.ago
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
