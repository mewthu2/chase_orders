# Estoque do Correios descontando o que está reservado (StockReservation). Vale para os pedidos do Honey: atacado,
# abastecimento e transferências. Com source, só contam as reservas que a escadinha manda aquela origem respeitar,
# no estoque dela (B2C → B2B olha o Log03; as demais, o Log02).
class B2bStockAvailability
  # O salvamento do pedido espera estas consultas: o Correios lento não pode travar a tela, e um
  # pedido com muitos SKUs não pode estourar o timeout da requisição.
  CORREIOS_TIMEOUT = 8
  MAX_THREADS = 8

  Result = Struct.new(:sku, :stock, :reserved, :available, :status, keyword_init: true) do
    def error? = status == 'error'
  end

  def self.for_sku(sku, exclude_tiny_order_id: nil, source: nil)
    sku = normalize(sku)
    account = account_for(source)
    build(sku, correios_stock(sku, account:), exclude_tiny_order_id:, account:, sources: counted_sources(source))
  end

  # Itens acima do disponível. SKUs sem resposta do Correios não entram (não bloqueiam).
  def self.shortages(items, exclude_tiny_order_id: nil, source: nil)
    requested = items.reject(&:marked_for_destruction?).each_with_object(Hash.new(0)) do |item, acc|
      sku = normalize(item.sku)
      acc[sku] += item.quantity.to_i if sku.present?
    end
    account = account_for(source)
    sources = counted_sources(source)
    stocks = correios_stocks(requested.keys, account:)

    requested.filter_map do |sku, quantity|
      result = build(sku, stocks[sku], exclude_tiny_order_id:, account:, sources:)
      next if result.error? || quantity <= result.available

      { sku:, requested: quantity, stock: result.stock, reserved: result.reserved, available: result.available }
    end
  end

  def self.status_for(available)
    return 'high' if available > 10

    available.positive? ? 'low' : 'out'
  end

  def self.normalize(sku) = sku.to_s.strip.upcase

  def self.account_for(source)
    source ? StockReservationPriority.account_of(source).to_sym : :b2b
  end

  def self.counted_sources(source)
    StockReservationPriority.counted_sources(source) if source
  end

  def self.build(sku, stock, exclude_tiny_order_id: nil, account: :b2b, sources: nil)
    reserved = StockReservation.reserved_for(sku, account:, exclude_tiny_order_id:, sources:)
    return Result.new(sku:, stock: 0, reserved:, available: 0, status: 'error') if stock.nil?

    available = stock - reserved
    Result.new(sku:, stock:, reserved:, available:, status: status_for(available))
  end

  # Consulta em paralelo, em lotes de MAX_THREADS. As threads só fazem HTTP (nada de banco).
  def self.correios_stocks(skus, account: :b2b)
    skus.each_slice(MAX_THREADS).each_with_object({}) do |slice, acc|
      slice.map { |sku| [sku, Thread.new { correios_stock(sku, account:) }] }.each { |sku, thread| acc[sku] = thread.value }
    end
  end

  def self.correios_stock(sku, account: :b2b)
    response = Correios::Orders.get_stock(sku, from_tiny2: account.to_s == 'b2b', timeout: CORREIOS_TIMEOUT)
    return nil unless response.respond_to?(:success?) && response.success?

    JSON.parse(response.body)['disponivel'].to_i
  rescue StandardError, Timeout::Error => e
    Rails.logger.error "B2bStockAvailability(#{sku}): #{e.class} #{e.message}"
    nil
  end
end
