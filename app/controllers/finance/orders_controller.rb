module Finance
  # Recebimentos dos pedidos de atacado: uma linha por parcela de boleto e uma por pedido PIX/cartão (pago na criação).
  # O mês filtra o vencimento (PIX/cartão: a data do pedido); parcelas vencidas de meses anteriores sempre aparecem.
  class OrdersController < ApplicationController
    guard_screen :finance_orders

    ORDER_INCLUDES = %i[client user consultant b2b_order_items payments].freeze

    # Consultor (quem recomendou) do pedido: escolher um cadastrado, digitar um nome livre ou tirar.
    def edit
      @order = B2bOrder.sale.find(params[:id])
      @consultants = Consultant.active.ordered.to_a
      @consultants |= [@order.consultant] if @order.consultant
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
      redirect_to params[:return_to].to_s.start_with?('/financeiro/pedidos') ? params[:return_to] : finance_orders_path,
                  notice: label ? "Pedido ##{order.id}: consultor #{label}." : "Pedido ##{order.id} ficou sem consultor."
    end

    def index
      @month = params[:mes].presence || Date.current.strftime('%Y-%m')
      range = date_range
      orders = B2bOrder.sale.where.not(status: :cancelado)

      created = orders.where(payment_method: %w[pix cartao])
      created = created.where(created_at: range.begin.beginning_of_day..range.end.end_of_day) if range
      payments = B2bOrderPayment.joins(:b2b_order).merge(orders)
      payments = payments.where(due_date: range).or(payments.where(paid_at: nil, due_date: ...range.begin)) if range

      @receivables = created.includes(*ORDER_INCLUDES).filter_map do |order|
        amount = order.creation_paid_amount
        next unless amount.positive?

        { order: order, payment: nil, due: order.created_at.to_date, amount: amount, paid_at: order.created_at.to_date }
      end
      @receivables += payments.includes(:paid_by, b2b_order: ORDER_INCLUDES).map do |p|
        { order: p.b2b_order, payment: p, due: p.due_date, amount: p.amount, paid_at: p.paid_at }
      end
    end

    private

    # Datas do filtro: um mês, um intervalo do calendário ou nil ("todos").
    def date_range
      return nil if @month == 'todos'
      if (range = HoneyTable.parse_range(@month))
        return range.begin.to_date..range.end.to_date
      end

      month = HoneyTable.parse_month(@month) || Date.current.beginning_of_month
      month..month.end_of_month
    end
  end
end
