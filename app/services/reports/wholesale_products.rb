module Reports
  # Análise de produtos do atacado (Adm › Dashboards e relatórios › Análise de produtos): as mesmas vendas do
  # painel Vendas Atacado (NF-e de venda autorizada em produção, sem pedidos de devolução), agrupadas pelo modelo
  # (nome sem o tamanho). Para cada modelo: faturamento e peças no período, curva ABC (A até 80% do faturamento,
  # B até 95%, C o resto), tendência contra o período anterior, última venda (histórico todo), preço médio contra
  # o custo e o varejo do cadastro e o giro das peças que entraram no Log02 pela Colocação de Estoque.
  # Candidato a outlet: parado há OUTLET_DAYS dias ou mais, curva C caindo forte, ou entrada no Log02 que quase
  # não girou depois de SLOW_DAYS dias.
  class WholesaleProducts
    A_LIMIT = 0.80
    B_LIMIT = 0.95
    OUTLET_DAYS = 90
    SLOW_DAYS = 60
    SLOW_SELL_THROUGH = 0.25
    DROP = -0.5

    STATUSES = {
      'outlet'   => ['Candidato a outlet', 'red', 'Parado, caindo forte ou sem giro no Log02.'],
      'parado'   => ['Sem venda no período', 'yellow', 'Vendeu antes, mas não neste período.'],
      'nunca'    => ['Nunca vendido', 'purple', 'Entrou no Log02 e ainda não teve venda no atacado.'],
      'ativo'    => ['Vendendo', 'green', 'Teve venda no período.']
    }.freeze
    CLASSES = { 'A' => ['A', 'green', 'Os que fazem 80% do faturamento.'], 'B' => ['B', 'blue', 'Os próximos 15%.'],
                'C' => ['C', 'gray', 'Os últimos 5%.'], '—' => ['—', 'gray', 'Sem venda no período.'] }.freeze

    BASES = { 'notas' => 'Notas emitidas', 'pedidos' => 'Pedidos (não cancelados)' }.freeze

    # basis: 'notas' (NF-e de venda autorizada, na data de emissão) ou 'pedidos' (pedidos de venda não cancelados,
    # na data do pedido; mostra a demanda antes de a nota sair).
    def initialize(period, today: Date.current, basis: 'notas')
      @period = period
      @today = today
      @basis = BASES.key?(basis.to_s) ? basis.to_s : 'notas'
    end

    attr_reader :period, :today, :basis

    # Uma linha por modelo, já com tudo calculado.
    def models
      @models ||= build_models
    end

    def sold = models.select { |m| m[:revenue].positive? }
    def revenue = sold.sum { |m| m[:revenue] }
    def pieces = sold.sum { |m| m[:pieces] }
    def by_status(key) = models.select { |m| m[:status] == key }
    def by_class(key) = sold.select { |m| m[:abc] == key }
    def outlet = by_status('outlet').sort_by { |m| [-(m[:days_since] || 9999), -m[:received].to_i] }

    def class_share(key) = revenue.positive? ? by_class(key).sum { |m| m[:revenue] } / revenue : 0
    def top10_share = revenue.positive? ? sold.first(10).sum { |m| m[:revenue] } / revenue : 0
    def avg_price = pieces.positive? ? revenue / pieces : 0

    def previous_totals
      @previous_totals ||= { revenue: models.sum { |m| m[:prev_revenue] }, pieces: models.sum { |m| m[:prev_pieces] },
                             models: models.count { |m| m[:prev_pieces].positive? } }
    end

    def delta(now, before)
      before.to_f.zero? ? nil : (now.to_f - before) / before
    end

    # Margem média ponderada pelo faturamento, só dos modelos com custo no cadastro.
    def avg_margin
      with_cost = sold.select { |m| m[:margin] }
      base = with_cost.sum { |m| m[:revenue] }
      base.positive? ? with_cost.sum { |m| m[:margin] * m[:revenue] } / base : nil
    end

    # Curva de Pareto: [{ label:, value:, cumulative:, abc: }] dos modelos vendidos, do maior para o menor.
    def pareto
      sold.map { |m| { label: m[:model], value: m[:revenue], cumulative: m[:cumulative], abc: m[:abc] } }
    end

    # Movers: quem mais subiu e mais caiu em peças contra o período anterior (com base mínima).
    def risers = models.select { |m| m[:trend] && m[:prev_pieces] >= 3 }.sort_by { |m| -m[:trend] }.first(8).select { |m| m[:trend].positive? }
    def fallers = models.select { |m| m[:trend] && m[:prev_pieces] >= 3 }.sort_by { |m| m[:trend] }.first(8).select { |m| m[:trend].negative? }

    def self.model_of(name, sku = nil)
      text = name.presence || sku.to_s
      text.to_s.sub(/\s+-\s+(PP|P|M|G|GG|XG|XGG|EG|U|UN|\d{1,2})\s*\z/i, '').strip
    end

    private

    def build_models
      lines = sale_lines
      in_period = lines.select { |l| period.range.cover?(l[:date]) }
      in_prev = lines.select { |l| period.previous.cover?(l[:date]) }
      by_model_all = lines.group_by { |l| l[:model] }
      cur = in_period.group_by { |l| l[:model] }
      prev = in_prev.group_by { |l| l[:model] }
      received = log02_receipts
      catalog = catalog_by_model

      keys = (by_model_all.keys | received.keys).uniq
      rows = keys.map do |model|
        list = cur[model].to_a
        all = by_model_all[model].to_a
        before = prev[model].to_a
        rev = list.sum { |l| l[:value] }
        pcs = list.sum { |l| l[:qty] }
        last_sale = all.map { |l| l[:date] }.max
        rec = received[model]
        sold_since_receipt = rec ? all.select { |l| l[:date] >= rec[:first] }.sum { |l| l[:qty] } : nil
        cat = catalog[model] || {}
        avg = pcs.positive? ? rev / pcs : nil
        prev_pcs = before.sum { |l| l[:qty] }
        {
          model: model, revenue: rev, pieces: pcs, orders: list.map { |l| l[:order_id] }.uniq.size, clients: list.map { |l| l[:client_id] }.compact.uniq.size,
          skus: (list.presence || all).map { |l| l[:sku] }.uniq.size, avg_price: avg,
          prev_revenue: before.sum { |l| l[:value] }, prev_pieces: prev_pcs, trend: prev_pcs.positive? ? (pcs - prev_pcs).to_f / prev_pcs : nil,
          last_sale: last_sale, days_since: last_sale && (today - last_sale).to_i, total_pieces: all.sum { |l| l[:qty] },
          cost: cat[:cost], retail: cat[:retail], margin: (avg && cat[:cost] && avg.positive? ? (avg - cat[:cost]) / avg : nil),
          retail_ratio: (avg && cat[:retail]&.positive? ? avg / cat[:retail] : nil),
          received: rec&.dig(:pieces), received_at: rec&.dig(:first), sell_through: (rec && rec[:pieces].positive? ? sold_since_receipt.to_f / rec[:pieces] : nil)
        }
      end

      classify_abc(rows)
      rows.each { |r| r[:status], r[:reason] = status_of(r) }
      rows.sort_by { |r| [-r[:revenue], -(r[:total_pieces] || 0), r[:model]] }
    end

    def classify_abc(rows)
      sold = rows.select { |r| r[:revenue].positive? }.sort_by { |r| -r[:revenue] }
      total = sold.sum { |r| r[:revenue] }
      acc = 0
      sold.each do |r|
        before = total.positive? ? acc / total : 0
        acc += r[:revenue]
        r[:share] = total.positive? ? r[:revenue] / total : 0
        r[:cumulative] = total.positive? ? acc / total : 0
        # A classe sai de onde o modelo começa na curva: o que cruza os 80% ainda é A.
        r[:abc] = if before < A_LIMIT then 'A' elsif before < B_LIMIT then 'B' else 'C' end
      end
      rows.each { |r| r[:abc] ||= '—'; r[:share] ||= 0 }
    end

    def status_of(r)
      if r[:days_since].nil?
        days = r[:received_at] && (today - r[:received_at]).to_i
        return ['outlet', "Entrou no Log02 há #{days} dias e nunca vendeu no atacado"] if days && days >= SLOW_DAYS

        return ['nunca', 'Entrou no Log02 e ainda não vendeu']
      end
      return ['outlet', "Sem venda há #{r[:days_since]} dias"] if r[:days_since] >= OUTLET_DAYS
      if r[:abc] == 'C' && r[:trend] && r[:trend] <= DROP
        return ['outlet', "Curva C e as peças caíram #{(r[:trend].abs * 100).round}% contra o período anterior"]
      end
      if r[:sell_through] && r[:received_at] && (today - r[:received_at]).to_i >= SLOW_DAYS && r[:sell_through] < SLOW_SELL_THROUGH
        return ['outlet', "Só #{(r[:sell_through] * 100).round}% das peças que entraram no Log02 venderam em #{(today - r[:received_at]).to_i} dias"]
      end
      return ['parado', "Sem venda no período (última há #{r[:days_since]} dias)"] if r[:revenue].zero?

      ['ativo', nil]
    end

    # Itens das NF-e de venda autorizadas em produção (histórico todo), um por item de pedido.
    def sale_lines
      dates = basis == 'pedidos' ? order_dates : note_dates
      return [] if dates.empty?

      clients = B2bOrder.where(id: dates.keys).pluck(:id, :client_id).to_h
      B2bOrderItem.where(b2b_order_id: dates.keys).pluck(:b2b_order_id, :sku, :name, :quantity, :price, :discount).map do |order_id, sku, name, qty, price, discount|
        { order_id: order_id, client_id: clients[order_id], date: dates[order_id], sku: sku.to_s, model: self.class.model_of(name, sku),
          qty: qty.to_i, value: (price.to_f * qty.to_i) - discount.to_f }
      end
    end

    def order_dates
      B2bOrder.sale.where(replacement: false).where.not(status: :cancelado).pluck(:id, :created_at).to_h { |id, at| [id, at.in_time_zone.to_date] }
    end

    def note_dates
      FiscalNote.principal.producao.autorizada.joins(:b2b_order)
                        .where(b2b_orders: { kind: B2bOrder.kinds[:sale], replacement: false })
                        .pluck(:b2b_order_id, Arel.sql('COALESCE(fiscal_notes.issued_at, fiscal_notes.authorized_at, fiscal_notes.created_at)'))
                        .each_with_object({}) { |(id, at), h| h[id] = [h[id], at.in_time_zone.to_date].compact.min }
    end

    # Peças que entraram no Log02 pela Colocação de Estoque, por modelo, com a data da primeira entrada.
    def log02_receipts
      placements = StockPlacement.where(side: 'log02').includes(stock_entry: :items).to_a
      return {} if placements.empty?

      names = Product.where(sku: placements.flat_map { |p| p.quantities.keys }.uniq).pluck(:sku, :shopify_product_name).to_h
      placements.each_with_object({}) do |p, acc|
        date = (p.stock_entry.issued_at || p.created_at).to_date
        entry_names = p.stock_entry.items.to_h { |i| [i.sku, i.description] }
        p.quantities.each do |sku, qty|
          model = self.class.model_of(names[sku].presence || entry_names[sku], sku)
          row = (acc[model] ||= { pieces: 0, first: date })
          row[:pieces] += qty
          row[:first] = [row[:first], date].min
        end
      end
    end

    # Custo e preço de varejo médios do cadastro de produtos, por modelo.
    def catalog_by_model
      Product.where.not(shopify_product_name: [nil, '']).pluck(:sku, :shopify_product_name, :cost, :price)
             .group_by { |_, name, _, _| self.class.model_of(name) }
             .transform_values do |list|
               costs = list.map { |r| r[2].to_s.tr(',', '.').to_f }.select(&:positive?)
               prices = list.map { |r| r[3].to_s.tr(',', '.').to_f }.select(&:positive?)
               { cost: costs.any? ? costs.sum / costs.size : nil, retail: prices.any? ? prices.sum / prices.size : nil }
             end
    end
  end
end
