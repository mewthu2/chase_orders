module Finance
  # Mantém as parcelas a receber de um pedido de atacado. Boleto (ou sem forma de pagamento, tratado como boleto
  # à vista) tem uma parcela por dia da condição ("30 60 90"), vencendo a partir da data do pedido. As parcelas já
  # pagas nunca mudam: as pendentes são refeitas dividindo o saldo (total com frete menos o já recebido). Se os prazos
  # acabarem antes do saldo (ex.: "30 60 90" com duas pagas virou "30 60"), o saldo vira uma parcela a mais.
  # PIX e cartão contam como pagos na criação: as pendentes somem e as pagas (de antes de trocar a forma) ficam.
  # Quando as pendentes já estão certas nada é mexido (os ids continuam os mesmos para a baixa em lote).
  class PaymentSchedule
    def self.call(order) = new(order).call

    # Parcelas do histórico: pedidos de venda não cancelados que ainda não têm nenhuma.
    def self.backfill!
      count = 0
      B2bOrder.sale.where.not(status: :cancelado).where.missing(:payments).includes(:b2b_order_items).find_each do |order|
        call(order)
        count += 1
      end
      count
    end

    def initialize(order)
      @order = order
    end

    def call
      return unless @order.sale? && @order.persisted?
      return if @order.cancelado?

      B2bOrderPayment.transaction do
        # Trava as parcelas do pedido: uma baixa feita ao mesmo tempo espera, em vez de ser apagada.
        payments = B2bOrderPayment.where(b2b_order_id: @order.id).order(:number).lock.to_a
        paid, pending = payments.partition(&:paid?)
        wanted = @order.paid_on_creation? ? [] : wanted_pending(paid)
        unless pending.map { |p| [p.number, p.due_date, p.amount] } == wanted
          B2bOrderPayment.where(id: pending.map(&:id), paid_at: nil).delete_all
          wanted.each { |number, due, amount| B2bOrderPayment.create!(b2b_order: @order, number: number, due_date: due, amount: amount) }
        end
      end
      @order.payments.reset
    end

    private

    # [[número, vencimento, valor], ...] das parcelas que ainda faltam receber.
    def wanted_pending(paid)
      balance = @order.grand_total - paid.sum(&:amount)
      return [] if balance <= 0

      days = @order.installment_days.presence || [0]
      taken = paid.map(&:number)
      open = days.each_with_index.map { |d, i| [i + 1, d] }.reject { |number, _| taken.include?(number) }
      open = [[taken.max.to_i + 1, days.last]] if open.empty?
      base = (@order.created_at || Time.current).to_date
      value = (balance / open.size).floor(2)
      open.each_with_index.map do |(number, d), i|
        [number, base + d, i == open.size - 1 ? balance - value * (open.size - 1) : value]
      end
    end
  end
end
