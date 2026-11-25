module Finance
  # Baixa (e desfazer a baixa) das parcelas de boleto dos pedidos de atacado, parcela a parcela: pelo quadradinho
  # da parcela em Financeiro › Notas Fiscais ou na tela do pedido.
  class PaymentsController < ApplicationController
    guard_screen :finance_orders, actions: { pay: :edit, unpay: :edit, pay_many: :edit }

    def pay
      payment = open_payments.find_by(id: params[:id])
      return back_to_list(alert: 'Parcela não encontrada ou o pedido foi cancelado.') unless payment

      payment.update!(paid_at: paid_at, paid_by: current_user)
      back_to_list(notice: "Parcela #{payment.number} do pedido ##{payment.b2b_order_id} baixada em #{I18n.l(payment.paid_at, format: '%d/%m/%Y')}.")
    end

    def unpay
      payment = open_payments.find_by(id: params[:id])
      return back_to_list(alert: 'Parcela não encontrada ou o pedido foi cancelado.') unless payment

      payment.update!(paid_at: nil, paid_by: nil)
      back_to_list(notice: "Baixa da parcela #{payment.number} do pedido ##{payment.b2b_order_id} desfeita.")
    end

    def pay_many
      scope = open_payments.pending.where(id: params[:ids].to_s.split(',').map(&:to_i).select(&:positive?))
      # "Pago no vencimento": cada parcela fica paga na data em que venceu (boletos antigos não caem todos no mês atual).
      count = if params[:on_due] == '1'
                scope.update_all(['b2b_order_payments.paid_at = b2b_order_payments.due_date, b2b_order_payments.paid_by_id = ?, b2b_order_payments.updated_at = ?', current_user.id, Time.current])
              else
                scope.update_all(paid_at: paid_at, paid_by_id: current_user.id, updated_at: Time.current)
              end
      back_to_list(notice: count.zero? ? 'Nenhuma parcela pendente selecionada.' : "#{count} #{count == 1 ? 'parcela baixada' : 'parcelas baixadas'}.")
    end

    private

    def open_payments
      B2bOrderPayment.joins(:b2b_order).merge(B2bOrder.sale.where.not(status: :cancelado))
    end

    def paid_at
      Date.iso8601(params[:paid_at].to_s)
    rescue Date::Error
      Date.current
    end

    def back_to_list(**flash)
      redirect_to helpers.finance_return_to, **flash
    end
  end
end
