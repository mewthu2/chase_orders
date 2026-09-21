# Conclui uma retirada de estoque: retira as quantidades direto no Shopify (ajuste de inventário
# com motivo e referência, que aparece no histórico do inventário) e registra o resultado por linha.
#
# - Uma chamada ao Shopify por location. Se o grupo for recusado, cada linha é tentada sozinha,
#   para que as boas passem e só as ruins falhem.
# - Linha acima do disponível não é retirada (falha com mensagem). O Shopify aceitaria saldo negativo.
# - Idempotente: só processa linhas pendentes ou com falha; linha já retirada nunca é enviada de novo.
# - Síncrono e sem fila: o resultado está na tela assim que a requisição termina.
class StockWithdrawalProcessor
  class Error < StandardError; end

  Summary = Struct.new(:done, :failed, keyword_init: true)

  # allow_negative: aceita retirar acima do disponível (o Shopify permite saldo negativo). É opt-in
  # explícito de quem concluiu; o padrão continua bloqueando linha acima do disponível.
  def self.call(withdrawal, user: nil, allow_negative: false)
    new(withdrawal, user: user, allow_negative: allow_negative).call
  end

  def initialize(withdrawal, user: nil, allow_negative: false)
    @withdrawal = withdrawal
    @allow_negative = allow_negative
    @user = user || withdrawal.user
    @inventory = ShopifyInventoryService.new
  end

  def call
    start!
    todo = @withdrawal.items.includes(:product, :location).where(status: [:pending, :failed]).to_a
    todo.group_by(&:location_id).each_value { |items| process_location(items) }
    finish!
  end

  private

  # with_lock impede duas execuções simultâneas; "processando" marca a execução em andamento.
  def start!
    @withdrawal.with_lock do
      raise Error, 'Esta retirada não pode ser processada agora.' unless @withdrawal.processable?

      @withdrawal.update!(status: :processing)
    end
  end

  def process_location(items)
    location = items.first.location
    shopify_location_id = location.shopify_location_id.presence
    return fail_all(items, "Location #{location.name} sem ID do Shopify") unless shopify_location_id

    available = @inventory.available_quantities(shopify_location_id, items.map { |i| i.product.shopify_inventory_item_id })
    ready = items.select { |item| check_line(item, available) }
    withdraw(shopify_location_id, ready) if ready.any?
  rescue StandardError => e
    Rails.logger.error "StockWithdrawalProcessor (retirada #{@withdrawal.id}, location #{location&.id}): #{e.class} #{e.message}"
    fail_all(items.reject(&:done?), "Erro ao consultar o Shopify: #{e.message}")
  end

  # Confere o disponível; devolve true se a linha pode ser retirada.
  def check_line(item, available)
    key = item.product.shopify_inventory_item_id.to_s
    return fail_line(item, 'Produto não encontrado nesta location do Shopify') && false unless available.key?(key)

    quantity = available[key]
    return fail_line(item, 'Produto não rastreado nesta location do Shopify') && false if quantity.nil?
    if item.quantity > quantity && !@allow_negative
      return fail_line(item, "Estoque insuficiente: disponível #{quantity}, retirada #{item.quantity}") && false
    end

    item.available_before = quantity
    true
  end

  def withdraw(shopify_location_id, items)
    result = adjust(shopify_location_id, items)
    if result[:success]
      items.each { |item| mark_done(item, result[:adjustment_id]) }
    else
      # Grupo recusado (operação atômica): tenta cada linha isolada para não perder as boas.
      items.each do |item|
        single = adjust(shopify_location_id, [item])
        single[:success] ? mark_done(item, single[:adjustment_id]) : fail_line(item, single[:error])
      end
    end
  end

  def adjust(shopify_location_id, items)
    @inventory.adjust_available(
      location_id: shopify_location_id,
      changes: items.map { |item| { inventory_item_id: item.product.shopify_inventory_item_id, delta: -item.quantity } },
      reason: @withdrawal.shopify_reason,
      reference_uri: @withdrawal.reference_uri
    )
  end

  def mark_done(item, adjustment_id)
    item.update!(status: :done, error_message: nil, shopify_adjustment_id: adjustment_id, withdrawn_at: Time.current)
    update_local_stock(item)
  end

  def fail_line(item, message)
    item.update!(status: :failed, error_message: message.to_s.first(500))
    true
  end

  def fail_all(items, message)
    items.each { |item| fail_line(item, message) }
  end

  # Espelha no produto o novo disponível da location (quando existe coluna local para ela).
  def update_local_stock(item)
    column = "stock_#{item.location.slug}"
    return unless item.product.respond_to?(column) && item.available_before

    item.product.update(column => item.available_before - item.quantity)
  end

  def finish!
    @withdrawal.refresh_status!
    items = @withdrawal.items
    failed = items.count { |item| item.failed? || item.pending? }
    log_completion(items.count(&:done?), failed)
    Summary.new(done: items.count(&:done?), failed: failed)
  end

  def log_completion(done, failed)
    LogService.create_log(
      user: @user, resource_type: 'stock_withdrawal', action_type: 'complete',
      resource_name: "Retirada ##{@withdrawal.id}", resource_id: @withdrawal.id,
      details: { done: done, failed: failed, reason: @withdrawal.reason, reference: @withdrawal.reference_uri, allow_negative: @allow_negative }
    )
  end
end
