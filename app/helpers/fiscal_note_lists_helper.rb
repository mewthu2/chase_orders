# Tabela das Notas Fiscais do Atacado (no Financeiro) e da Logística (FiscalNoteListsController). A mesma montagem
# serve à tela e ao ZIP dos XML, que baixa exatamente o que os filtros mostram. A do atacado tem ainda o status do
# pedido e o recebimento (parcelas do boleto).
module FiscalNoteListsHelper
  FISCAL_LIST_STATUSES = {
    'rascunho' => ['Gerada, falta emitir', 'yellow', 'Gerada e assinada para conferir. Só vai à SEFAZ quando alguém clicar em Emitir na SEFAZ.'],
    'assinada' => ['Assinada', 'blue', 'Arquivo pronto e assinado. Falta enviar à SEFAZ.'],
    'autorizada' => ['Autorizada', 'green', 'A SEFAZ aceitou a nota e ela vale.'],
    'rejeitada' => ['Rejeitada', 'red', 'A SEFAZ recusou a nota. O motivo aparece nos detalhes.'],
    'cancelada' => ['Cancelada', 'purple', 'Era uma nota autorizada e foi cancelada.'],
    'erro' => ['Erro', 'orange', 'Não deu para assinar ou enviar a nota.']
  }.freeze
  FISCAL_LIST_TYPES = {
    'sale' => ['Venda', 'blue', 'Nota do pedido de atacado.'],
    'stock_transfer' => ['Abastecimento', 'orange', 'Nota do abastecimento de uma loja.'],
    'b2c_transfer' => ['Transferência', 'purple', 'Nota da transferência entre o estoque de atacado (B2B) e a loja online (B2C).'],
    'remessa' => ['Remessa', 'gray', 'Nota de remessa da transferência ou do abastecimento (a segunda nota do pedido, o N.r).']
  }.freeze
  FISCAL_LIST_ENVIRONMENTS = { 'producao' => ['Produção', 'green', 'Nota de verdade, com valor fiscal.'],
                               'homologacao' => ['Homologação', 'yellow', 'Nota de teste, sem valor fiscal.'] }.freeze

  def fiscal_note_list_table(list_key, scope)
    logistics = list_key == 'logistica'
    money = ->(value) { number_to_currency(value, unit: 'R$ ', separator: ',', delimiter: '.') }
    today = Date.current
    can_order = screen_can?(:b2b_orders)
    order_link = lambda do |note|
      order = note.b2b_order
      if can_order
        link_to("##{order.id}", b2b_order_edit_path(order, tab: 'nota', anchor: ('remessaNote' if note.remessa?)), class: 'text-main t mono',
                data: { tip: 'Abrir a nota no pedido' })
      elsif !logistics
        link_to("##{order.id}", edit_finance_order_path(order, return_to: request.fullpath), class: 'text-main t mono', data: { tip: 'Parcelas e consultor do pedido' })
      else
        content_tag(:span, "##{order.id}", class: 'mono')
      end
    end
    map = lambda do |note|
      order = note.b2b_order
      receipt = finance_receipt(order, today) unless logistics
      { id: note.id, record: note, num: note.number, serieTxt: "Série #{note.series}", serie: note.series, st: note.status,
        tipo: note.remessa? ? 'remessa' : order.kind, empresa: note.company.selection_label, amb: note.environment,
        pedido: order_link.call(note),
        dest: b2b_order_destination(order).presence || '—', valor: note.total_value.to_f, pag: note.payment_method.presence || '—',
        emissao: note.issued_at || note.created_at, natureza: note.operation_nature.presence || '—', cfop: note.cfop_summary.presence || '—',
        chave: note.access_key.to_s.scan(/\d{1,4}/).join(' ').presence || '—', protocolo: note.protocol.presence || '—', erro: note.error_message,
        ost: order.status, rec: receipt&.dig(:status), recTxt: receipt&.dig(:text), abertas: receipt&.dig(:open).to_i,
        consultor: order.consultant_label || '—', vendedor: order.user&.name || '—' }
    end
    search = lambda do |s, text|
      term = "%#{ActiveRecord::Base.sanitize_sql_like(text.strip.delete_prefix('#'))}%"
      digits = text.gsub(/\D/, '')
      s.left_joins(:company).where('fiscal_notes.number LIKE :t OR fiscal_notes.b2b_order_id LIKE :t OR companies.legal_name LIKE :t OR companies.trade_name LIKE :t' +
                                   (digits.length >= 4 ? ' OR fiscal_notes.access_key LIKE :k' : ''), t: term, k: "%#{digits}%")
    end
    type_sql = lambda do |s, v|
      case v
      when 'remessa' then s.where(role: 'remessa')
      when *B2bOrder.kinds.keys then s.where(role: nil, b2b_orders: { kind: B2bOrder.kinds[v] })
      else s
      end
    end
    active_value = ->(s) { money.call(s.except(:includes).where(status: FiscalNote::ACTIVE_STATUSES).sum(:total_value)) }
    # Parcelas sem baixa dos pedidos (não cancelados) das notas do filtro.
    open_payments = lambda do |s|
      B2bOrderPayment.pending.joins(:b2b_order).where.not(b2b_orders: { status: :cancelado })
                     .where(b2b_order_id: s.unscope(:includes, :order, :limit, :offset).select('fiscal_notes.b2b_order_id'))
    end
    unpaid_sql = 'EXISTS (SELECT 1 FROM b2b_order_payments p WHERE p.b2b_order_id = fiscal_notes.b2b_order_id AND p.paid_at IS NULL%s)'
    receipt_sql = lambda do |s, v|
      overdue = ActiveRecord::Base.sanitize_sql_array([format(unpaid_sql, ' AND p.due_date < ?'), today])
      case v
      when 'pago' then s.where("NOT #{format(unpaid_sql, '')}")
      when 'vencido' then s.where(overdue)
      when 'pendente' then s.where(format(unpaid_sql, '')).where("NOT #{overdue}")
      else s
      end
    end
    order_statuses = b2b_order_statuses
    types = FISCAL_LIST_TYPES.slice(*(logistics ? %w[stock_transfer b2c_transfer remessa] : %w[sale]))

    HoneyQueryTable.new(params, scope: scope, map: map, search: search, page_size: 50, unit: 'notas', unit1: 'nota', sort: { k: :emissao, dir: -1 },
      attrs: { st: :status, empresa: :company_id, pag: :payment_method },
      filter_sql: { tipo: type_sql, rec: receipt_sql,
                    ost: ->(s, v) { s.where(b2b_orders: { status: B2bOrder.statuses.values_at(*v.to_s.split(',')).compact }) } },
      sort_sql: { num: 'fiscal_notes.number', valor: 'fiscal_notes.total_value', emissao: 'COALESCE(fiscal_notes.issued_at, fiscal_notes.created_at)' },
      cols: [
        { k: :num, label: 'Nº', t: :num, plain: true, main: true, sub: :serieTxt, sort: true },
        { k: :serieTxt, label: 'Série', hide: true, nodetail: true },
        ({ k: :tipo, label: 'Tipo', t: :status, map: types } if logistics),
        { k: :st, label: 'Situação', t: :status, map: FISCAL_LIST_STATUSES },
        { k: :empresa, label: 'Empresa' },
        { k: :pedido, label: 'Pedido', t: :html, sub: :dest },
        { k: :dest, label: logistics ? 'Destino' : 'Cliente', hide: true },
        { k: :valor, label: 'Valor da nota', t: :money, sort: true },
        ({ k: :pag, label: 'Pagamento', t: :status, map: FiscalNote::PAYMENT_LABELS.merge('—' => ['—', 'gray', 'Nota sem a forma de pagamento gravada.']) } unless logistics),
        ({ k: :rec, label: 'Recebimento', t: :status, map: FinanceHelper::FINANCE_RECEIPT_STATUSES, sub: :recTxt } unless logistics),
        ({ k: :recTxt, label: 'Parcelas', hide: true } unless logistics),
        ({ k: :ost, label: 'Status do pedido', t: :status, map: order_statuses } unless logistics),
        ({ k: :consultor, label: 'Consultor', hide: true } unless logistics),
        ({ k: :vendedor, label: 'Vendedor', hide: true } unless logistics),
        { k: :amb, label: 'Ambiente', t: :status, map: FISCAL_LIST_ENVIRONMENTS, hide: true },
        { k: :emissao, label: 'Emitida em', t: :dt, sort: true },
        { k: :natureza, label: 'Natureza da operação', hide: true },
        { k: :cfop, label: 'CFOP', hide: true },
        { k: :chave, label: 'Chave de acesso', hide: true },
        { k: :protocolo, label: 'Protocolo de autorização', hide: true }
      ].compact,
      filters: [
        { id: :mes, type: :month, label: 'Mês', tip: 'Mês de emissão da nota. As setas trocam de mês, o calendário escolhe de um dia a outro e no fim da lista dá para ver todos os meses.' },
        { id: :q, type: :search, label: 'Buscar', ph: 'Número, pedido, empresa ou chave…', tip: 'Procura no número da nota, no pedido, na empresa e na chave de acesso.' },
        ({ id: :tipo, type: :select, label: 'Tipo', col: :tipo, options: types.map { |k, v| [k, v[0]] }, all: 'Todos os tipos', tip: 'Abastecimento, transferência B2B ⇄ B2C ou a nota de remessa.' } if logistics),
        { id: :status, type: :select, label: 'Situação', col: :st, all: 'Todas as situações', tip: 'Em que ponto a nota está.' },
        ({ id: :ost, type: :select, label: 'Status do pedido', col: :ost, all: 'Todos os status', options: order_statuses.map { |k, v| [k, v[0]] },
           tip: 'Em que ponto está o pedido, da aprovação no Log02 até a entrega.' } unless logistics),
        ({ id: :rec, type: :select, label: 'Recebimento', col: :rec, all: 'Todos', options: FinanceHelper::FINANCE_RECEIPT_STATUSES.map { |k, v| [k, v[0]] },
           tip: 'Pago, a receber (parcela sem baixa dentro do vencimento) ou vencido.' } unless logistics),
        { id: :amb, type: :select, label: 'Ambiente', col: :amb, server: true, all: 'Produção',
          options: [%w[homologacao Homologação], ['todos', 'Produção e homologação']], tip: 'Produção são as notas com valor fiscal. Homologação são as de teste.' }
      ].compact,
      kpis: [
        { label: 'Notas no filtro', icon: 'fas fa-file-invoice', tone: 'gray', help: 'Todas as notas que a lista mostra.', filtered: true, value: ->(s) { s.except(:includes).count } },
        { label: 'Autorizadas', icon: 'fas fa-circle-check', tone: 'green', help: 'Valem na SEFAZ.', filtered: true, value: ->(s) { s.except(:includes).where(status: :autorizada).count } },
        { label: 'Canceladas', icon: 'fas fa-ban', tone: 'purple', help: 'Autorizadas e depois canceladas.', filtered: true, value: ->(s) { s.except(:includes).where(status: :cancelada).count } },
        { label: 'Valor das notas ativas', icon: 'fas fa-sack-dollar', tone: 'yellow', filtered: true, value: active_value,
          help: 'Valor total das notas da lista (produtos, frete, seguro e despesas, menos desconto). Cancelada, rejeitada e com erro não entram.' },
        ({ label: 'A receber', icon: 'fas fa-hourglass-half', tone: 'yellow', filtered: true, value: ->(s) { money.call(open_payments.call(s).sum(:amount)) },
           help: 'Parcelas de boleto ainda sem baixa dos pedidos das notas da lista (vencidas ou não).' } unless logistics),
        ({ label: 'Vencido', icon: 'fas fa-triangle-exclamation', tone: 'red', filtered: true, value: ->(s) { money.call(open_payments.call(s).where(due_date: ...today).sum(:amount)) },
           help: 'Parcelas sem baixa com o vencimento já passado.' } unless logistics)
      ].compact)
  end
end
