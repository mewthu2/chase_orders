module Tiny::Orders
  module_function

  def get_all_orders(kind, situacao, function, data)
    case kind
    when 'bh_shopping'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
    when 'lagoa_seca'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION')
    when 'rj'
      token = ENV.fetch('TOKEN_TINY_PRODUCTION_RJ')
    when 'tiny_3'
      token = ENV.fetch('TOKEN_TINY3_PRODUCTION')
    end

    response = get_orders_response(kind, situacao, token, '', data)

    total = []

    if response['numero_paginas'].present? && response['numero_paginas'] > 1
      (1..response['numero_paginas']).each do |page_number|
        page_response = get_orders_response(kind, situacao, token, page_number, data)
        total.concat(page_response['pedidos']) if page_response['pedidos'].present?
      end
    elsif response['pedidos'].present?
      total.concat(response['pedidos'])
    end

    case function
    when 'update_orders'
      process_orders(token, total, kind)
    when 'process_for_shopify'
      process_for_shopify(total, kind)
      total
    else
      total
    end
  end

  def process_for_shopify(orders, kind)
    orders.each do |order_data|
      pedido = order_data['pedido']
      tiny_order_id = pedido['id']

      next unless should_process_order?(pedido, kind)

      begin
        sleep(1)
        CreateShopifyOrdersFromTinyJob.perform_now(kind, tiny_order_id)
        puts "[Tiny->Shopify] Pedido #{pedido['numero']} (#{tiny_order_id}) enfileirado"
      rescue StandardError => e
        handle_enqueue_error(pedido, kind, e)
      end
    end
  end

  def should_process_order?(pedido, kind)
    return false unless pedido['situacao'] == 'Entregue'

    !Attempt.where(
      tiny_order_id: pedido['id'],
      status: :success,
      requisition: 'Pedido Shopify criado com sucesso'
    ).where('tracking LIKE ?', "%kind:#{kind}%").exists?
  end

  def handle_enqueue_error(pedido, kind, error)
    puts "[ERRO] Ao enfileirar pedido #{pedido['numero']}: #{error.message}"

    Attempt.create(
      tiny_order_id: pedido['id'],
      status: Attempt.statuses[:failed],
      error: error.message,
      tracking: "#{kind}|enqueue_error",
      classification: 'enqueue_error'
    )
  end

  def process_orders(token, pedidos, kind)
    pedidos.each do |pedido|
      order = Order.find_or_create_by(
        kinds: kind,
        tiny_order_id: pedido['pedido']['id']
      )

      order.update(tags: pedido['pedido']['nome_vendedor'], tiny_creation_date: pedido['pedido']['data_pedido']) if pedido['pedido']['nome_vendedor'].present?

      attempt = Attempt.where(
        status: :success,
        requisition: 'Pedido Shopify criado com sucesso',
        tiny_order_id: pedido['pedido']['id']
      ).where('tracking LIKE ?', "%kind:#{kind}%").first

      if attempt&.tracking.present?
        match = attempt.tracking.match(/shopify_order_id:(\d+)/)
        shopify_order_id = match[1] if match

        order.update(shopify_order_id:) if shopify_order_id.present?
      end

      tiny_order = obtain_order(token, pedido['pedido']['id'])

      sleep(0.5)

      next unless tiny_order['pedido'].present?

      tiny_order['pedido']['itens'].each do |oi|
        product = Product.find_by(sku: oi['item']['codigo'])

        create_or_update_order_item(kind, order, pedido, oi, product)
      end
    end
  end

  def create_or_update_order_item(kind, order, pedido, oi, product)
    order_item = OrderItem.find_or_initialize_by(
      order_id: order.id,
      order_tiny_id: pedido['pedido']['id'],
      sku: oi['item']['codigo'],
      "order_date_#{kind}": pedido['pedido']['data_pedido']
    )

    order_item.assign_attributes(
      quantity: oi['item']['quantidade'],
      price: oi['item']['valor_unitario'],
      product_id: product&.id,
      tiny_product_id: oi['item']['id_produto']
    )

    order_item.save
  end

  def get_orders_response(kind, situacao, token, page, data = nil)
    base_query = {
      token:,
      formato: 'json',
      situacao:,
      pagina: page
    }

    if kind == 'lagoa_seca'
      base_query[:dataInicial] = '01/09/2024'
      base_query[:marcadores] = 'PDV'
    elsif data.present?
      base_query[:dataInicial] = data
    end

    response = HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'), query: base_query)
    JSON.parse(response).with_indifferent_access[:retorno]
  end

  def obtain_order(token, order_id)
    response = JSON.parse(HTTParty.get(ENV.fetch('OBTER_PEDIDO'),
                                       query: { token:,
                                                formato: 'json',
                                                id: order_id }))
    response.with_indifferent_access[:retorno]
  end

  def send_tracking(order_id, tracking)
    response = JSON.parse(HTTParty.get(ENV.fetch('TINY_SEND_TRACKING'),
                                       query: { token: ENV.fetch('TOKEN_TINY3_PRODUCTION'),
                                                formato: 'json',
                                                id: order_id,
                                                codigoRastreamento: tracking }))
    response.with_indifferent_access[:retorno]
  end

  def change_situation(order_id, new_situation)
    response = JSON.parse(HTTParty.get(ENV.fetch('ALTERAR_SITUACAO_PEDIDO'),
                                       query: { token: ENV.fetch('TOKEN_TINY3_PRODUCTION'),
                                                formato: 'string',
                                                id: order_id,
                                                situacao: new_situation }))
    response.with_indifferent_access[:retorno]
  end
end
