class Tiny::Orders
  class << self
    def get_all_orders(kind, situacao, function, pagina = nil)
      case kind
      when 'lagoa_seca'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION')
      when 'bh_shopping'
        token = ENV.fetch('TOKEN_TINY_PRODUCTION_BH_SHOPPING')
      end

      response = get_orders_response(situacao, token, pagina)

      total = []

      if response['numero_paginas'].present? && response['numero_paginas'].positive?
        (1..response['numero_paginas']).each do |page_number|
          total << get_orders_response(situacao, token, page_number)
        end
      else
        total << response
      end

      case function
      when 'update_orders'
        total.each do |orders_list|
          process_orders(token, orders_list['pedidos'], kind)
        end
      else
        total
      end
    end

    def process_orders(token, pedidos, kind)
      pedidos.each do |pedido|
        order = Order.find_or_create_by(kinds: kind,
                                        tiny_order_id: pedido['pedido']['id']
                                        created_at: pedido['pedido']['data_pedido'])

        tiny_order = obtain_order(token, pedido['pedido']['id'])

        print 'dormiu meio segundo'
        sleep(0.5)
        print 'acordou'

        next unless tiny_order['pedido'].present?

        tiny_order['pedido']['itens'].each do |oi|
          OrderItem.find_or_create_by(order_id: order.id,
                                      quantity: oi['item']['quantidade'],
                                      price: oi['item']['valor_unitario'],
                                      product_id: oi['item']['id_produto'],
                                      sku: oi['item']['codigo'])
        end
      end
    end

    def get_orders_response(situacao, token, page)
      response = JSON.parse(HTTParty.get(ENV.fetch('PEDIDOS_PESQUISA'),
                                         query: { token:,
                                                  formato: 'json',
                                                  situacao:,
                                                  pagina: page }))
      response.with_indifferent_access[:retorno]
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
end
