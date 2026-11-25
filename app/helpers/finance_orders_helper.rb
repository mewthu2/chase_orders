module FinanceOrdersHelper
  FINANCE_PAYMENT_STATUSES = {
    'pago' => ['Pago', 'green', 'Recebido.'], 'pendente' => ['Pendente', 'yellow', 'Boleto ainda não pago, dentro do vencimento.'],
    'vencido' => ['Vencido', 'red', 'Boleto não pago e já vencido.']
  }.freeze

  # Tabela de Financeiro › Pedidos de Atacado. A tela, a planilha e o ZIP de XML usam a mesma, para o
  # "todo o filtro" ser exatamente o que a lista mostra.
  def finance_receivables_table(receivables)
    money = ->(v) { number_to_currency(v, unit: 'R$ ', separator: ',', delimiter: '.') }
    today = Date.current
    rows = receivables.map do |r|
      order = r[:order]
      payment = r[:payment]
      st = r[:paid_at] ? 'pago' : (r[:due] < today ? 'vencido' : 'pendente')
      consultant = order.consultant_label
      pending_tag = hc_status('cadastro pendente', 'yellow', tip: 'Nome digitado no pedido, sem cadastro. Cadastre ou vincule em Financeiro › Consultores.') if order.consultant_pending?
      { id: payment ? payment.id.to_s : "o#{order.id}", record: payment, order: order, num: order.id,
        pedido: link_to("##{order.id}", b2b_order_edit_path(order), class: 'text-main t mono', data: { tip: 'Abrir o pedido' }),
        cliente: b2b_order_destination(order).presence || '—',
        parcela: payment ? "#{payment.number}/#{order.payments.size}" : 'À vista',
        forma: order.payment_description.presence || 'Sem forma (boleto à vista)',
        consultor: consultant ? safe_join([consultant, pending_tag].compact, ' ') : '—',
        consultor_txt: consultant.to_s, digitador: order.user&.name || '—',
        valor: r[:amount].to_f, venc: r[:due], pago_em: r[:paid_at], pago_txt: r[:paid_at] ? l(r[:paid_at], format: '%d/%m/%Y') : '—',
        st: st, ost: order.status, quem: payment&.paid_by&.name || (payment ? '—' : 'Na criação (PIX/cartão)') }
    end
    sum = ->(sts) { rows.select { |r| sts.include?(r[:st]) }.sum { |r| r[:valor] } }

    HoneyTable.new(params, rows: rows, unit: 'recebimentos', unit1: 'recebimento', page_size: 25, sort: { k: :venc, dir: 1 },
      tabs: { col: :st, items: [['', 'Todos'], ['pendente', 'Pendentes'], ['vencido', 'Vencidos'], ['pago', 'Pagos']] },
      cols: [
        { k: :pedido, label: 'Pedido', t: :html, sub: :cliente, main: true },
        { k: :cliente, label: 'Cliente', hide: true },
        { k: :parcela, label: 'Parcela', sub: :forma },
        { k: :forma, label: 'Forma de pagamento', hide: true },
        { k: :consultor, label: 'Consultor', t: :html, sub: :digitador },
        { k: :digitador, label: 'Vendedor', hide: true },
        { k: :valor, label: 'Valor', t: :money, sort: true },
        { k: :venc, label: 'Vencimento', t: :d, sort: true },
        { k: :pago_txt, label: 'Pago em', sub: :quem },
        { k: :quem, label: 'Baixa por', hide: true },
        { k: :st, label: 'Situação', t: :status, map: FINANCE_PAYMENT_STATUSES },
        { k: :ost, label: 'Status do pedido', t: :status, map: b2b_order_statuses.except('cancelado') }
      ],
      filters: [
        { id: :ost, type: :select, label: 'Status do pedido', col: :ost, all: 'Todos os status', tip: 'Em que ponto está o pedido, da aprovação no Log02 até a entrega.' },
        { id: :mes, type: :month, label: 'Vencimento', server: true, default: params[:mes].presence || today.strftime('%Y-%m'),
          tip: 'Mês do vencimento da parcela (PIX e cartão: a data do pedido). Use "todos" para ver tudo.' },
        { id: :q, type: :search, label: 'Buscar', ph: 'Pedido, cliente, consultor…', cols: %i[num cliente consultor_txt digitador], tip: 'Procura no número do pedido, no cliente, no consultor e no vendedor.' }
      ],
      kpis: [
        { label: 'Recebido', icon: 'fas fa-circle-check', tone: 'green', help: 'Pago no filtro: PIX e cartão e as parcelas com baixa.', text: money.call(sum.call(%w[pago])) },
        { label: 'A receber', icon: 'fas fa-hourglass-half', tone: 'yellow', help: 'Parcelas de boleto ainda sem baixa (vencidas ou não).', text: money.call(sum.call(%w[pendente vencido])) },
        { label: 'Vencido', icon: 'fas fa-triangle-exclamation', tone: 'red', help: 'Parcelas sem baixa com o vencimento já passado.', text: money.call(sum.call(%w[vencido])) },
        { label: 'Parcelas vencidas', icon: 'fas fa-file-invoice-dollar', tone: 'red', help: 'Quantas estão vencidas. Clique para ver só elas.', col: :st, val: 'vencido' }
      ])
  end

  # O que o JS da seleção precisa de cada linha do filtro (todas as páginas): chave, parcela, valor e se dá baixa.
  def finance_selection_rows(table)
    table.matching.map { |r| { k: r[:id], p: r[:record]&.id, v: r[:valor], o: r[:st] != 'pago' && r[:record].present? } }
  end
end
