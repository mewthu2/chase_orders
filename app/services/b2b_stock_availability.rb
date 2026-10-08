# Estoque do Correios B2B descontando o que está reservado na fila do Tiny2 (StockReservation b2b).
# Vale para todos os pedidos B2B: venda/atacado, abastecimento e transferência B2C.
class B2bStockAvailability
  # O salvamento do pedido espera estas consultas: o Correios lento não pode travar a tela, e um
  # pedido com muitos SKUs não pode estourar o timeout da requisição.
  CORREIOS_TIMEOUT = 8
  MAX_THREADS = 8

  Result = Struct.new(:sku, :stock, :reserved, :available, :status, keyword_init: true) do
    def error? = status == 'error'
  end

  def self.for_sku(sku)
    sku = normalize(sku)
    build(sku, correios_stock(sku))
  end

  # Itens acima do disponível. SKUs sem resposta do Correios não entram (não bloqueiam).
  def self.shortages(items)
    requested = items.reject(&:marked_for_destruction?).each_with_object(Hash.new(0)) do |item, acc|
      sku = normalize(item.sku)
      acc[sku] += item.quantity.to_i if sku.present?
    end
    stocks = correios_stocks(requested.keys)

    requested.filter_map do |sku, quantity|
      result = build(sku, stocks[sku])
      next if result.error? || quantity <= result.available

      { sku:, requested: quantity, stock: result.stock, reserved: result.reserved, available: result.available }
    end
  end

  def self.status_for(available)
    return 'high' if available > 10

    available.positive? ? 'low' : 'out'
  end

  def self.normalize(sku) = sku.to_s.strip.upcase

  def self.build(sku, stock)
    reserved = StockReservation.reserved_for(sku, account: :b2b)
    return Result.new(sku:, stock: 0, reserved:, available: 0, status: 'error') if stock.nil?

    available = stock - reserved
    Result.new(sku:, stock:, reserved:, available:, status: status_for(available))
  end

  # Consulta em paralelo, em lotes de MAX_THREADS. As threads só fazem HTTP (nada de banco).
  def self.correios_stocks(skus)
    skus.each_slice(MAX_THREADS).each_with_object({}) do |slice, acc|
      slice.map { |sku| [sku, Thread.new { correios_stock(sku) }] }.each { |sku, thread| acc[sku] = thread.value }
    end
  end

  def self.correios_stock(sku)
    response = Correios::Orders.get_stock(sku, from_tiny2: true, timeout: CORREIOS_TIMEOUT)
    return nil unless response.respond_to?(:success?) && response.success?

    JSON.parse(response.body)['disponivel'].to_i
  rescue StandardError, Timeout::Error => e
    Rails.logger.error "B2bStockAvailability(#{sku}): #{e.class} #{e.message}"
    nil
  end
end
