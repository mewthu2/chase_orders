module Correios::StuckOrders
  module_function

  STOCK_ERROR_MESSAGE = 'Produto(s) informado(s) não existe(m) no estoque:'.freeze

  # Pedidos que a Tiny tentou criar no Correios e falharam por falta desse SKU
  # no estoque, considerando apenas a tentativa MAIS RECENTE de cada pedido —
  # a lista de produtos sem estoque de um pedido muda a cada nova tentativa
  # (o job roda periodicamente), então uma tentativa antiga pode citar um SKU
  # que já não falta mais na tentativa atual.
  def summary_for_sku(sku, from_tiny2: false)
    sku_upcase = sku.to_s.strip.upcase
    return { orders_count: 0, total_quantity: 0.0 } if sku_upcase.blank?

    kind = from_tiny2 ? :create_correios_order_tiny2 : :create_correios_order
    window = 1.month.ago..Time.current

    successfully_processed_ids = Attempt.where(kinds: kind, status: :success, created_at: window)
                                        .pluck(:tiny_order_id).map(&:to_s)

    stock_error_attempts = Attempt.where(kinds: kind, created_at: window)
                                  .where.not(message: [nil, ''])
                                  .where('message LIKE ?', "#{ActiveRecord::Base.sanitize_sql_like(STOCK_ERROR_MESSAGE)}%")
                                  .to_a

    # find_each/order don't mix (find_each always paginates by id ASC), so we
    # group in Ruby and pick each order's most recent attempt explicitly.
    latest_attempt_by_order = stock_error_attempts
      .group_by do |attempt|
        attempt.tiny_order_id.to_s.presence ||
          extract_param(attempt.params.to_s, :pedido_id) ||
          extract_param(attempt.params.to_s, :invoice)
      end
      .except(nil, '')
      .except(*successfully_processed_ids)
      .transform_values { |attempts| attempts.max_by(&:created_at) }

    order_ids = []
    total_quantity = 0.0

    latest_attempt_by_order.each do |tiny_order_id, attempt|
      codes = extract_missing_stock_product_codes(attempt.message)
      next unless codes.any? { |code| code.upcase == sku_upcase }

      order_ids << tiny_order_id
      total_quantity += extract_item_quantity(attempt.params.to_s, sku_upcase).to_s.tr(',', '.').to_f
    end

    { orders_count: order_ids.size, total_quantity: total_quantity }
  end

  def extract_missing_stock_product_codes(message)
    message.to_s
           .split(STOCK_ERROR_MESSAGE, 2)
           .last
           .to_s
           .split(/[,\s]+/)
           .map { |code| code.gsub(/[^\w\-.]/, '') }
           .reject(&:blank?)
           .uniq
  end

  def extract_param(attempt_params, key)
    attempt_params.match(/:#{Regexp.escape(key.to_s)}=>"([^"]*)"/)&.captures&.first
  end

  def extract_item_quantity(attempt_params, product_code)
    item_match = attempt_params.scan(/\{[^{}]*:codigo=>"#{Regexp.escape(product_code)}"[^{}]*\}/).first

    item_match&.match(/:quantidade=>"([^"]*)"/)&.captures&.first || '0'
  end
end
