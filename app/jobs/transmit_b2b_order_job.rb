class TransmitB2bOrderJob < ActiveJob::Base
  queue_as :default

  def perform(b2b_order_id)
    order = B2bOrder.find(b2b_order_id)

    # with_lock: dois jobs para o mesmo pedido (ex.: duplo clique) nunca enviam ao mesmo tempo.
    order.with_lock do
      # Já enviado (ou cancelado): não cria outro pedido no Tiny nem sobrescreve o status vindo dele.
      next if order.tiny_reference_id.present? || order.cancelado?

      service = B2bTinyService.new
      result = order.sale? ? service.create_sale_order(order) : service.create_stock_transfer(order)

      if result[:success]
        order.update!(status: :aberto, error_message: nil,
                      tiny_reference_id: result[:tiny_reference_id], tiny_reference_number: result[:tiny_reference_number])
      else
        order.update!(status: :dados_incompletos, error_message: result[:error])
      end
    end
  end
end
