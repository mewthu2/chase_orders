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
