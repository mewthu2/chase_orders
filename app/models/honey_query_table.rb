# HoneyTable para listas grandes: filtra, conta, ordena e pagina no banco. Só a página atual vira
# linhas (map). O HTML é o mesmo do HoneyTable (HoneyPageHelper#hc_pg_table).
#
#   HoneyQueryTable.new(params, scope:, map: ->(record) { row },
#     attrs: { st: :status },                      # coluna da tela => atributo do banco (abas, indicadores, selects)
#     search: ->(scope, text) { scope.where(...) }, # busca (filtro :search)
#     sort_sql: { n: 'b2b_orders.id' },             # ordenação por coluna
#     filter_sql: { periodo: ->(scope, v) { ... } }, # filtros que não são um atributo direto
#     preload: ->(records) { ... },                  # carrega dados extras só da página atual
#     ...mesmas opções do HoneyTable)
class HoneyQueryTable < HoneyTable
  def initialize(params, scope:, map:, attrs: {}, search: nil, sort_sql: {}, filter_sql: {}, preload: nil, **options)
    @preload = preload
    @scope = scope
    @map = map
    @attrs = attrs
    @search = search
    @sort_sql = sort_sql
    @filter_sql = filter_sql
    super(params, rows: [], **options)
  end

  def total = @total ||= filtered_scope.except(:select).count
  # preload: ->(registros) { ... } roda uma vez com os registros da página, antes do map.
  def page_rows
    @page_rows ||= begin
      records = sorted_scope.offset((page - 1) * page_size).limit(page_size).to_a
      @preload&.call(records)
      records.map(&@map)
    end
  end

  def kpi_value(kpi)
    return kpi[:text] if kpi.key?(:text)
    return kpi[:count] if kpi.key?(:count)
    return kpi[:value].call(@scope) if kpi[:value].respond_to?(:call)

    attr = @attrs[kpi[:col]] or return @scope.except(:select).count
    counts = (@counts ||= {})[attr] ||= @scope.except(:select).reorder(nil).group(attr).count.transform_keys(&:to_s)
    kpi_vals(kpi).sum { |v| counts[v].to_i }
  end

  def tab_count(tab)
    return @scope.except(:select).count if tab[0].to_s.empty?
    return tabs[:filter].call(@scope, tab[0].to_s).except(:select).count if tabs[:filter]

    attr = @attrs[tabs[:col]]
    counts = (@counts ||= {})[attr] ||= @scope.except(:select).reorder(nil).group(attr).count.transform_keys(&:to_s)
    tab[0].to_s.split(',').sum { |v| counts[v].to_i }
  end

  def filter_options(filter)
    return filter[:options] if filter[:options]

    super
  end

  private

  def filtered_scope
    @filtered_scope ||= begin
      out = @scope
      if tabs && tab_index.to_i.positive? && (tab = tabs[:items][tab_index]) && tab[0].to_s.present?
        out = tabs[:filter] ? tabs[:filter].call(out, tab[0].to_s) : out.where(@attrs[tabs[:col]] => tab[0].to_s.split(','))
      end
      if kpi_index && (kpi = kpis[kpi_index])
        out = kpi[:filter] ? kpi[:filter].call(out) : (@attrs[kpi[:col]] ? out.where(@attrs[kpi[:col]] => kpi_vals(kpi)) : out)
      end
      filters.each do |f|
        value = filter_value(f) or next
        out = if @filter_sql[f[:id]] then @filter_sql[f[:id]].call(out, value)
              elsif f[:type] == :search && @search then @search.call(out, value)
              elsif f[:type] == :period && @attrs[f[:col]] then out.where(@attrs[f[:col]] => period_start(value)..)
              elsif @attrs[f[:col]] then out.where(@attrs[f[:col]] => value.to_s.split(','))
              else out
              end
      end
      out
    end
  end

  def sorted_scope
    s = sort
    column = s && @sort_sql[s[:k]]
    return filtered_scope unless column

    filtered_scope.reorder(Arel.sql("#{column} #{s[:dir] == -1 ? 'DESC' : 'ASC'}"))
  end
end
