module Finance
  # Comissões de um mês, calculadas na hora a partir dos pedidos de atacado, das parcelas pagas e dos percentuais do
  # mês (CommissionRate). Nada é gravado: cancelar, corrigir um pedido ou vincular um consultor reflete sozinho.
  #
  # - Quem digitou o pedido (b2b_orders.user): total com frete dos pedidos criados no mês.
  # - Consultor: PIX e cartão, o total no mês do pedido; boleto (ou sem forma), cada parcela no mês da baixa.
  #   Sem cadastro, o consultor aparece pelo nome digitado, como pendente e sem percentual.
  class Commissions
    Entry = Data.define(:order, :payment, :date, :base)
    Row = Data.define(:role, :key, :name, :beneficiary, :pending, :percent, :base, :commission, :entries)

    attr_reader :month

    def initialize(month:)
      @month = month.to_date.beginning_of_month
    end

    def range = month.beginning_of_day..month.end_of_month.end_of_day

    def rows
      @rows ||= begin
        rates = CommissionRate.for_month(month)
        typist_rows(rates) + consultant_rows(rates)
      end
    end

    def totals
      { base: rows.sum(&:base), commission: rows.sum(&:commission) }
    end

    def find(key) = rows.find { |r| r.key == key }

    private

    def orders = B2bOrder.sale.where.not(status: :cancelado).includes(:user, :consultant, :client, :b2b_order_items, :payments)

    def typist_rows(rates)
      orders.where(created_at: range).group_by(&:user).filter_map do |user, list|
        next unless user

        entries = list.map { |o| Entry.new(order: o, payment: nil, date: o.created_at.to_date, base: o.grand_total) }
        build(:typist, "User-#{user.id}", user.name, user, false, rates[['User', user.id]], entries)
      end.sort_by { |r| r.name.to_s.downcase }
    end

    def consultant_rows(rates)
      entries = orders.where(created_at: range, payment_method: %w[pix cartao]).filter_map do |o|
        amount = o.creation_paid_amount
        Entry.new(order: o, payment: nil, date: o.created_at.to_date, base: amount) if amount.positive?
      end
      payments = B2bOrderPayment.paid.where(paid_at: month..month.end_of_month)
                                .where(b2b_order_id: orders.select(:id)).includes(b2b_order: %i[user consultant client b2b_order_items payments])
      entries += payments.map { |p| Entry.new(order: p.b2b_order, payment: p, date: p.paid_at, base: p.amount) }

      groups = entries.select { |e| e.order.consultant_label }.group_by { |e| consultant_key(e.order) }
      groups.map do |key, list|
        order = list.first.order
        consultant = order.consultant
        if consultant
          build(:consultant, key, consultant.name, consultant, false, rates[['Consultant', consultant.id]], list)
        else
          build(:consultant, key, order.salesperson_name.squish, nil, true, nil, list)
        end
      end.sort_by { |r| r.name.to_s.downcase }
    end

    def consultant_key(order)
      order.consultant_id ? "Consultant-#{order.consultant_id}" : "name-#{order.salesperson_name.squish.downcase}"
    end

    def build(role, key, name, beneficiary, pending, percent, entries)
      entries = entries.sort_by(&:date)
      base = entries.sum(&:base)
      commission = percent ? (base * percent / 100).round(2) : BigDecimal('0')
      Row.new(role: role, key: key, name: name, beneficiary: beneficiary, pending: pending, percent: percent,
              base: base, commission: commission, entries: entries)
    end
  end
end
