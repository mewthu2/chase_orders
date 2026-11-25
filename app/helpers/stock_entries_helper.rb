module StockEntriesHelper
  def stock_money(value) = number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.')
  def stock_qty(value) = number_with_delimiter(value.to_i, delimiter: '.')

  # Lista das notas de entrada (as duas telas usam a mesma).
  def stock_entries_table(entries)
    rows = entries.map do |e|
      sides = StockPlacement::SIDES.keys.to_h { |s| [s, e.placement(s)] }
      { id: e.id, record: e, num: e.number, serie: "Série #{e.series}", fornecedor: e.supplier_name.to_s, cnpj: Nfe::Cnpj.format(e.supplier_cnpj),
        empresa: e.company&.trade_name.presence || e.company&.legal_name || '—', emissao: e.issued_at&.to_date, itens: e.items.size,
        pecas: e.pieces, valor: e.total_value.to_f, st: e.status,
        log02: sides['log02'] ? "#{stock_qty(sides['log02'].pieces)} peças" : '—', log03: sides['log03'] ? "#{stock_qty(sides['log03'].pieces)} peças" : '—',
        chave: e.access_key.scan(/\d{1,4}/).join(' ') }
    end
    HoneyTable.new(params, rows: rows, unit: 'notas', unit1: 'nota', page_size: 25, sort: { k: :emissao, dir: -1 },
      cols: [
        { k: :num, label: 'Nº', t: :num, plain: true, main: true, sub: :serie, sort: true },
        { k: :serie, label: 'Série', hide: true, nodetail: true },
        { k: :fornecedor, label: 'Fornecedor', sub: :cnpj, sort: true },
        { k: :cnpj, label: 'CNPJ do fornecedor', hide: true },
        { k: :empresa, label: 'Para' },
        { k: :emissao, label: 'Emissão', t: :d, sort: true },
        { k: :itens, label: 'Itens', t: :qty },
        { k: :pecas, label: 'Peças', t: :qty, sort: true },
        { k: :valor, label: 'Valor da nota', t: :money, sort: true },
        { k: :log02, label: 'Log02' },
        { k: :log03, label: 'Log03' },
        { k: :st, label: 'Colocação', t: :status, map: StockEntry::STATUSES },
        { k: :chave, label: 'Chave de acesso', hide: true }
      ],
      filters: [
        { id: :q, type: :search, label: 'Buscar', ph: 'Número, fornecedor, CNPJ ou chave…', cols: %i[num fornecedor cnpj chave] },
        { id: :st, type: :select, label: 'Colocação', col: :st, all: 'Todas' }
      ],
      kpis: [
        { label: 'Notas de entrada', icon: 'fas fa-file-import', tone: 'blue', help: 'Todas as importadas.', count: rows.size },
        { label: 'Aguardando colocação', icon: 'fas fa-hourglass-half', tone: 'yellow', help: 'Sem CSV do Log02 e do Log03.', col: :st, vals: ['aguardando'] },
        { label: 'Em colocação', icon: 'fas fa-boxes-stacked', tone: 'blue', help: 'Com CSV ou nota, falta terminar.', col: :st, vals: ['em_colocacao'] },
        { label: 'Colocadas', icon: 'fas fa-circle-check', tone: 'green', help: 'As duas remessas autorizadas.', col: :st, vals: ['colocada'] }
      ])
  end
end
