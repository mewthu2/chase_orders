class CartService
  CART_TTL = 24.hours.to_i
  COUPON_TTL = 24.hours.to_i

  def initialize(session_id)
    @session_id = session_id
    @cart_key = "cart:#{session_id}"
    @coupon_key = "coupon:#{session_id}"
  end

  def get_cart_items
    begin
      cart_data = $redis.get(@cart_key)
      cart_data ? JSON.parse(cart_data) : []
    rescue Redis::BaseError, JSON::ParserError => e
      Rails.logger.error "Erro ao buscar carrinho: #{e.message}"
      []
    end
  end

  def set_cart_items(items)
    begin
      $redis.multi do |multi|
        multi.set(@cart_key, items.to_json)
        multi.expire(@cart_key, CART_TTL)
      end

      Rails.logger.info "Carrinho salvo no Redis: #{items.count} itens"
      true
    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao salvar carrinho: #{e.message}"
      false
    end
  end

  def add_item(product_id, product_data, quantity = 1)
    begin
      $redis.watch(@cart_key)

      current_items = get_cart_items
      existing_item = current_items.find { |item| item['product_id'] == product_id.to_s }

      if existing_item
        existing_item['quantity'] = existing_item['quantity'].to_i + quantity
        Rails.logger.info "Item existente atualizado: #{product_id} -> quantidade #{existing_item['quantity']}"
      else
        new_item = {
          'product_id' => product_id.to_s,
          'sku' => product_data[:sku],
          'name' => product_data[:name],
          'price' => product_data[:price].to_f,
          'quantity' => quantity,
          'option1' => product_data[:option1],
          'image_url' => product_data[:image_url],
          'store_type' => product_data[:store_type] || 'lagoa_seca',
          'added_at' => Time.current.to_i
        }

        current_items << new_item
        Rails.logger.info "Novo item adicionado: #{new_item}"
      end

      result = $redis.multi do |multi|
        multi.set(@cart_key, current_items.to_json)
        multi.expire(@cart_key, CART_TTL)
      end

      if result
        Rails.logger.info "Carrinho atualizado com sucesso: #{current_items.count} itens"
        {
          success: true,
          cart_items: current_items,
          unique_count: current_items.count,
          total_items: current_items.sum { |item| item['quantity'].to_i }
        }
      else
        Rails.logger.error "Falha na transação Redis"
        { success: false, error: 'Falha ao salvar no Redis' }
      end

    rescue Redis::BaseError => e
      Rails.logger.error "Erro Redis ao adicionar item: #{e.message}"
      { success: false, error: e.message }
    ensure
      $redis.unwatch
    end
  end

  def remove_item(product_id)
    begin
      $redis.watch(@cart_key)

      current_items = get_cart_items
      current_items.reject! { |item| item['product_id'] == product_id.to_s }

      result = $redis.multi do |multi|
        multi.set(@cart_key, current_items.to_json)
        multi.expire(@cart_key, CART_TTL)
      end

      if result
        Rails.logger.info "Item removido: #{product_id}"
        {
          success: true,
          cart_items: current_items,
          unique_count: current_items.count,
          total_items: current_items.sum { |item| item['quantity'].to_i }
        }
      else
        { success: false, error: 'Falha ao remover item' }
      end

    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao remover item: #{e.message}"
      { success: false, error: e.message }
    ensure
      $redis.unwatch
    end
  end

  def update_item_quantity(product_id, new_quantity)
    begin
      $redis.watch(@cart_key)

      current_items = get_cart_items
      item = current_items.find { |item| item['product_id'] == product_id.to_s }

      return { success: false, error: 'Item não encontrado' } unless item

      if new_quantity <= 0
        current_items.reject! { |item| item['product_id'] == product_id.to_s }
      else
        item['quantity'] = new_quantity
      end

      result = $redis.multi do |multi|
        multi.set(@cart_key, current_items.to_json)
        multi.expire(@cart_key, CART_TTL)
      end

      if result
        {
          success: true,
          cart_items: current_items,
          item_total: item ? item['price'].to_f * item['quantity'].to_i : 0
        }
      else
        { success: false, error: 'Falha ao atualizar quantidade' }
      end

    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao atualizar quantidade: #{e.message}"
      { success: false, error: e.message }
    ensure
      $redis.unwatch
    end
  end

  def clear_cart
    begin
      result = $redis.multi do |multi|
        multi.del(@cart_key)
        multi.del(@coupon_key)
      end

      Rails.logger.info "Carrinho limpo"
      { success: true }
    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao limpar carrinho: #{e.message}"
      { success: false, error: e.message }
    end
  end

  def get_applied_coupon
    begin
      coupon_data = $redis.get(@coupon_key)
      coupon_data ? JSON.parse(coupon_data) : nil
    rescue Redis::BaseError, JSON::ParserError => e
      Rails.logger.error "Erro ao buscar cupom: #{e.message}"
      nil
    end
  end

  def apply_coupon(coupon_data)
    begin
      result = $redis.multi do |multi|
        multi.set(@coupon_key, coupon_data.to_json)
        multi.expire(@coupon_key, COUPON_TTL)
      end

      Rails.logger.info "Cupom aplicado: #{coupon_data['code']}"
      { success: true }
    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao aplicar cupom: #{e.message}"
      { success: false, error: e.message }
    end
  end

  def remove_coupon
    begin
      $redis.del(@coupon_key)
      Rails.logger.info "Cupom removido"
      { success: true }
    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao remover cupom: #{e.message}"
      { success: false, error: e.message }
    end
  end

  def calculate_total(cart_items = nil)
    items = cart_items || get_cart_items
    items.sum { |item| item['price'].to_f * item['quantity'].to_i }
  end

  def get_cart_summary
    cart_items = get_cart_items
    applied_coupon = get_applied_coupon

    subtotal = calculate_total(cart_items)
    discount_amount = applied_coupon ? applied_coupon['discount_amount'].to_f : 0
    total = subtotal - discount_amount

    {
      cart_items: cart_items,
      unique_count: cart_items.count,
      total_items: cart_items.sum { |item| item['quantity'].to_i },
      subtotal: subtotal,
      discount_amount: discount_amount,
      total: total,
      applied_coupon: applied_coupon
    }
  end

  def extend_ttl
    begin
      should_expire_cart = $redis.exists(@cart_key)
      should_expire_coupon = $redis.exists(@coupon_key)

      $redis.multi do |multi|
        multi.expire(@cart_key, CART_TTL) if should_expire_cart
        multi.expire(@coupon_key, COUPON_TTL) if should_expire_coupon
      end
    rescue Redis::BaseError => e
      Rails.logger.error "Erro ao estender TTL: #{e.message}"
    end
  end

  def debug_info
    begin
      cart_ttl = $redis.ttl(@cart_key)
      coupon_ttl = $redis.ttl(@coupon_key)

      {
        session_id: @session_id,
        cart_key: @cart_key,
        coupon_key: @coupon_key,
        cart_exists: $redis.exists(@cart_key) == 1,
        coupon_exists: $redis.exists(@coupon_key) == 1,
        cart_ttl: cart_ttl,
        coupon_ttl: coupon_ttl,
        redis_info: $redis.info('memory')['used_memory_human']
      }
    rescue Redis::BaseError => e
      { error: e.message }
    end
  end

  def migrate_from_session(session_cart_items, session_coupon)
    begin
      if session_cart_items.present? && get_cart_items.empty?
        Rails.logger.info "Migrando carrinho da sessão para Redis: #{session_cart_items.count} itens"
        set_cart_items(session_cart_items)
      end

      if session_coupon.present? && get_applied_coupon.nil?
        Rails.logger.info "Migrando cupom da sessão para Redis: #{session_coupon['code']}"
        apply_coupon(session_coupon)
      end

      { success: true }
    rescue => e
      Rails.logger.error "Erro na migração: #{e.message}"
      { success: false, error: e.message }
    end
  end
end
