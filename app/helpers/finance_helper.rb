module FinanceHelper
  FINANCE_PAYMENT_STATUSES = {
    'pago' => ['Pago', 'green', 'Recebido. Para o consultor, a comissão sai no mês do pagamento.'],
    'pendente' => ['Pendente', 'yellow', 'Boleto ainda não pago, dentro do vencimento.'],
    'vencido' => ['Vencido', 'red', 'Boleto não pago e já vencido.']
  }.freeze
  # Recebimento do pedido inteiro, na tela de Notas Fiscais do Financeiro.
  FINANCE_RECEIPT_STATUSES = FINANCE_PAYMENT_STATUSES.merge(
    'pago' => ['Pago', 'green', 'PIX/cartão (pago na criação) ou todas as parcelas do boleto com baixa.'],
    'pendente' => ['A receber', 'yellow', 'Tem parcela de boleto sem baixa, nenhuma vencida.'],
    'vencido' => ['Vencido', 'red', 'Tem parcela de boleto sem baixa e já vencida.']
  ).freeze

  # Para onde voltar depois da baixa ou do consultor: só telas do Financeiro; senão, as Notas Fiscais.
  def finance_return_to
    back = params[:return_to].to_s
    back.start_with?('/financeiro/') && !back.start_with?('//') ? back : wholesale_fiscal_notes_path
  end

  def finance_payment_status(payment, today = Date.current)
    return 'pago' if payment.paid?

    payment.due_date < today ? 'vencido' : 'pendente'
  end

  # Rótulo do quadradinho da parcela: o prazo dela em dias (30, 60...) ou o número, se o prazo não bate.
  def finance_parcel_label(order, payment)
    days = order.installment_days[payment.number - 1]
    days ? days.to_s : "#{payment.number}ª"
  end

  # Coluna Recebimento: a situação e, no boleto, um quadradinho por parcela (clique abre a baixa: fin-parcel).
  def finance_receipt_cell(order, receipt, today = Date.current)
    label, tone, tip = FINANCE_RECEIPT_STATUSES.fetch(receipt[:status])
    payments = order.payments.to_a
    return safe_join([hc_status(label, tone, tip: tip), content_tag(:span, receipt[:text], class: 'cell-sub')]) if payments.empty?

    chips = payments.each_with_index.map do |p, i|
      st = finance_payment_status(p, today)
      text = finance_parcel_label(order, p)
      info = { id: p.id, order: order.id, n: p.number, total: payments.size, days: text, due: l(p.due_date, format: '%d/%m/%Y'),
               dueIso: p.due_date.iso8601, value: number_to_currency(p.amount, unit: 'R$ ', separator: ',', delimiter: '.'), st: st,
               stLabel: FINANCE_PAYMENT_STATUSES.dig(st, 0), paid: p.paid_at && l(p.paid_at, format: '%d/%m/%Y'), by: p.paid_by&.name,
               client: b2b_order_destination(order).to_s, cancelled: order.status == 'cancelado',
               pay: pay_finance_payment_path(p), unpay: unpay_finance_payment_path(p),
               terms: (edit_finance_order_path(order, return_to: request.fullpath, anchor: 'prazos') if order.payment_method == 'boleto') }
      content_tag(:button, type: 'button', class: "fin-chip is-#{st}", style: "--n: #{i}", data: { fin_parcel: info.to_json, tip: "Parcela #{p.number}/#{payments.size} · #{text.end_with?('ª') ? '' : "#{text} dias · "}vence #{info[:due]} · #{info[:value]} · #{info[:stLabel]}" },
                                  'aria-label': "Parcela #{p.number} de #{payments.size}, #{info[:stLabel]}") do
        safe_join([text, (content_tag(:i, '', class: 'fas fa-check') if st == 'pago')].compact)
      end
    end
    safe_join([hc_status(label, tone, tip: tip), content_tag(:span, receipt[:text], class: 'cell-sub'), content_tag(:div, safe_join(chips), class: 'fin-chips')])
  end

  # Para a planilha: "30d 10/12/2026 R$ 100,00 Pago em 05/12/2026; 60d ...".
  def finance_parcels_text(order, today = Date.current)
    order.payments.map do |p|
      st = finance_payment_status(p, today)
      label = finance_parcel_label(order, p)
      [("#{label}d" unless label.end_with?('ª')) || label, l(p.due_date, format: '%d/%m/%Y'), number_to_currency(p.amount, unit: 'R$ ', separator: ',', delimiter: '.'),
       st == 'pago' ? "Pago em #{l(p.paid_at, format: '%d/%m/%Y')}" : FINANCE_PAYMENT_STATUSES.dig(st, 0)].join(' ')
    end.join('; ').presence || (order.paid_on_creation? ? "#{order.payment_label}, pago na criação" : '')
  end

  # 'pago', 'pendente' ou 'vencido' do pedido, com o resumo ("2/3 parcelas pagas", "PIX, pago na criação").
  def finance_receipt(order, today = Date.current)
    payments = order.payments.to_a
    open = payments.reject(&:paid?)
    status = if open.any? { |p| p.due_date < today } then 'vencido'
             elsif open.any? then 'pendente'
             else 'pago'
             end
    text = if payments.empty? then order.paid_on_creation? ? "#{order.payment_label}, pago na criação" : 'Sem parcelas'
           else "#{payments.size - open.size}/#{payments.size} #{payments.size == 1 ? 'parcela paga' : 'parcelas pagas'}"
           end
    { status: status, text: text, open: open.size, open_value: open.sum(&:amount).to_f }
  end
end
