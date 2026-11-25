module Finance
  # Recebimento de um pedido de atacado, aberto da tela Financeiro › Notas Fiscais: as parcelas do boleto (com
  # baixa e desfazer, e os prazos, que dá para aumentar ou diminuir) ou o PIX/cartão pago na criação, e o consultor
  # (quem recomendou), que dá para trocar ou tirar.
  class OrdersController < ApplicationController
    guard_screen :finance_orders, actions: { edit: :view, terms: :edit, due: :edit }

    def edit
      @order = B2bOrder.sale.includes(payments: :paid_by).find(params[:id])
      @consultants = Consultant.active.ordered.to_a
      @consultants |= [@order.consultant] if @order.consultant
    end

    # Prazos do boleto ("30 60 90"): mais ou menos parcelas. As pagas não mudam; o saldo é redividido entre as
    # pendentes (Finance::PaymentSchedule). Só pedido de boleto, não cancelado.
    def terms
      order = B2bOrder.sale.find(params[:id])
      back = edit_finance_order_path(order, return_to: helpers.finance_return_to)
      return redirect_to(back, alert: 'Só dá para mudar as parcelas de pedido no boleto.') unless order.payment_method == 'boleto'
      return redirect_to(back, alert: 'Pedido cancelado: as parcelas não mudam.') if order.cancelado?

      days = params[:payment_terms].to_s.tr(',;/', '   ').split
      error = terms_error(order, days)
      return redirect_to(back, alert: error) if error

      before = order.payment_terms
      order.update_columns(payment_terms: days.join(' '), updated_at: Time.current)
      Finance::PaymentSchedule.call(order)
      Rails.logger.info("[Financeiro] pedido ##{order.id}: prazos do boleto #{before.inspect} -> #{order.payment_terms.inspect} por #{current_user.email}")
      redirect_to back, notice: "Pedido ##{order.id}: boleto em #{days.size}x (#{order.payment_terms})."
    end

    # Vencimento de uma parcela pendente do boleto. O vencimento vira o prazo em dias daquela parcela (contado da data
    # do pedido), e as parcelas são refeitas pelo Finance::PaymentSchedule: assim a data escolhida não se perde
    # quando o pedido muda depois. Precisa ficar depois da parcela anterior e antes da seguinte.
    def due
      order = B2bOrder.sale.find(params[:id])
      back = edit_finance_order_path(order, return_to: helpers.finance_return_to)
      return redirect_to(back, alert: 'Só dá para mudar o vencimento de pedido no boleto.') unless order.payment_method == 'boleto'
      return redirect_to(back, alert: 'Pedido cancelado: as parcelas não mudam.') if order.cancelado?

      payment = order.payments.find_by(number: params[:number].to_i)
      return redirect_to(back, alert: 'Parcela não encontrada.') unless payment
      return redirect_to(back, alert: "A parcela #{payment.number} já está paga: desfaça a baixa para mudar o vencimento.") if payment.paid?

      date = begin
        Date.iso8601(params[:due_date].to_s)
      rescue Date::Error
        nil
      end
      return redirect_to(back, alert: 'Escolha a nova data de vencimento.') unless date

      days = order.installment_days
      index = payment.number - 1
      return redirect_to(back, alert: 'Esta parcela não está nos prazos do pedido: ajuste pelos prazos do boleto abaixo.') if index >= days.size

      base = (order.created_at || Time.current).to_date
      offset = (date - base).to_i
      return redirect_to(back, alert: "O vencimento não pode ser antes da data do pedido (#{I18n.l(base, format: '%d/%m/%Y')}).") if offset.negative?
      return redirect_to(back, alert: 'Vencimento longe demais: até 999 dias depois do pedido.') if offset > 999

      days[index] = offset
      if days.each_cons(2).any? { |a, b| b <= a }
        return redirect_to(back, alert: "A parcela #{payment.number} precisa vencer depois da anterior e antes da seguinte.")
      end

      before = payment.due_date
      order.update_columns(payment_terms: days.join(' '), updated_at: Time.current)
      Finance::PaymentSchedule.call(order)
      Rails.logger.info("[Financeiro] pedido ##{order.id}: vencimento da parcela #{payment.number} #{before} -> #{date} por #{current_user.email}")
      redirect_to back, notice: "Parcela #{payment.number} do pedido ##{order.id} passou a vencer em #{I18n.l(date, format: '%d/%m/%Y')}."
    end

    def update
      order = B2bOrder.sale.find(params[:id])
      name = params[:name].to_s.squish
      consultant = if params[:remove].present? then nil
                   elsif params[:consultant_id].present? then Consultant.find(params[:consultant_id])
                   elsif name.present? then Consultant.find_by('LOWER(name) = ?', name.downcase)
                   end
      order.update_columns(consultant_id: consultant&.id, salesperson_name: params[:remove].present? ? nil : (consultant&.name || name.presence),
                           updated_at: Time.current)
      label = order.consultant_label
      redirect_to edit_finance_order_path(order, return_to: helpers.finance_return_to),
                  notice: label ? "Pedido ##{order.id}: consultor #{label}." : "Pedido ##{order.id} ficou sem consultor."
    end

    private

    def terms_error(order, days)
      return 'Informe os prazos em dias, por exemplo: 30 60 90.' if days.empty?
      return 'Use só números de dias, separados por espaço (ex.: 30 60 90).' unless days.all? { |d| d.match?(/\A\d{1,3}\z/) }

      numbers = days.map(&:to_i)
      return "No máximo #{B2bOrder::MAX_INSTALLMENTS} parcelas." if numbers.size > B2bOrder::MAX_INSTALLMENTS
      return 'Os prazos precisam crescer: cada parcela vence depois da anterior (ex.: 30 60 90).' unless numbers.each_cons(2).all? { |a, b| b > a }

      paid = order.payments.select(&:paid?).map(&:number).max.to_i
      "Já tem #{paid} #{paid == 1 ? 'parcela paga' : 'parcelas pagas'}: deixe pelo menos #{paid} parcelas." if numbers.size < paid
    end
  end
end
