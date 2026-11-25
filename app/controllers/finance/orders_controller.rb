module Finance
  # Recebimento de um pedido de atacado, aberto da tela Financeiro › Notas Fiscais: as parcelas do boleto (com
  # baixa e desfazer) ou o PIX/cartão pago na criação, e o consultor (quem recomendou), que dá para trocar ou tirar.
  class OrdersController < ApplicationController
    guard_screen :finance_orders, actions: { edit: :view }

    def edit
      @order = B2bOrder.sale.includes(payments: :paid_by).find(params[:id])
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
      redirect_to edit_finance_order_path(order, return_to: helpers.finance_return_to),
                  notice: label ? "Pedido ##{order.id}: consultor #{label}." : "Pedido ##{order.id} ficou sem consultor."
    end
  end
end
