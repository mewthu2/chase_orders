module Whatsapp
  # Consultas que o agente pode fazer antes de responder, conforme as funcionalidades da automação:
  #   consultar_estoque → em quais lojas tem o produto (estoque "available" da Shopify por local)
  #   buscar_pedidos    → pedidos da Shopify pelo e-mail que a cliente escreveu na conversa
  # graphql: ->(query, variables) { corpo da resposta } (nos testes, um dublê; por padrão a Admin API da Shopify).
  class AgentTools
    SHOP = 'chasebrasil.myshopify.com'.freeze
    MAX_GROUPS = 4
    MAX_VARIANTS = 40
    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    ONLINE_SLUG = 'log+'.freeze

    FINANCIAL = { 'PAID' => 'pago', 'PENDING' => 'aguardando pagamento', 'AUTHORIZED' => 'pagamento autorizado',
                  'PARTIALLY_PAID' => 'pago em parte', 'REFUNDED' => 'reembolsado', 'PARTIALLY_REFUNDED' => 'reembolsado em parte',
                  'VOIDED' => 'pagamento cancelado', 'EXPIRED' => 'pagamento expirado' }.freeze
    FULFILLMENT = { 'UNFULFILLED' => 'ainda não enviado', 'FULFILLED' => 'enviado', 'PARTIALLY_FULFILLED' => 'enviado em parte',
                    'IN_PROGRESS' => 'em separação', 'ON_HOLD' => 'em espera', 'SCHEDULED' => 'agendado',
                    'PENDING_FULFILLMENT' => 'em separação', 'OPEN' => 'em separação', 'RESTOCKED' => 'devolvido ao estoque' }.freeze
    SHIPMENT = { 'DELIVERED' => 'entregue', 'IN_TRANSIT' => 'em trânsito', 'OUT_FOR_DELIVERY' => 'saiu para entrega',
                 'ATTEMPTED_DELIVERY' => 'tentativa de entrega', 'READY_FOR_PICKUP' => 'pronto para retirada',
                 'LABEL_PRINTED' => 'etiqueta gerada', 'LABEL_PURCHASED' => 'etiqueta gerada', 'CONFIRMED' => 'postagem confirmada',
                 'FULFILLED' => 'enviado', 'FAILURE' => 'problema na entrega', 'CANCELED' => 'envio cancelado' }.freeze

    attr_reader :used

    # keys: funcionalidades em uso; history: a conversa (para conferir que o e-mail veio da cliente).
    def initialize(keys, history, graphql: nil)
      @keys = keys.map(&:to_s) & AutomationCapability::CATALOG.keys
      @history = history
      @graphql = graphql
      @used = []
    end

    def any? = @keys.any?

    def definitions
      @keys.map { |key| send("#{key}_definition") }
    end

    # Executa a ferramenta pedida pelo modelo; erros viram resposta para o modelo, nunca exceção.
    def call(name, raw_args)
      args = raw_args.is_a?(Hash) ? raw_args : (JSON.parse(raw_args.to_s) rescue {})
      result = case name
               when 'consultar_estoque' then @keys.include?('stock_lookup') ? stock(args['produto'], args['tamanho']) : unavailable
               when 'buscar_pedidos' then @keys.include?('order_lookup') ? orders(args['email'], args['numero']) : unavailable
               else unavailable
               end
      @used << { name: name, args: args.slice('produto', 'tamanho', 'email', 'numero'), result: result }
      result
    rescue StandardError => e
      Rails.logger.warn "Whatsapp::AgentTools #{name}: #{e.class}: #{e.message}"
      result = { erro: 'A consulta falhou agora. Diga que vai verificar com a equipe e já retorna.' }
      @used << { name: name, args: args || {}, result: result }
      result
    end

    private

    def unavailable = { erro: 'Esta consulta não está disponível.' }

    def stock_lookup_definition
      { type: 'function', function: {
        name: 'consultar_estoque',
        description: 'Consulta em quais lojas da CHASE tem um produto disponível agora (estoque da Shopify).',
        parameters: { type: 'object', additionalProperties: false, required: ['produto'],
                      properties: { produto: { type: 'string', description: 'Produto como a cliente descreveu: tipo, linha/modelo e cor. Ex.: "legging signature black".' },
                                    tamanho: { type: 'string', description: 'Tamanho pedido (PP, P, M, G, GG…), se a cliente disse.' } } }
      } }
    end

    def order_lookup_definition
      { type: 'function', function: {
        name: 'buscar_pedidos',
        description: 'Busca os pedidos da loja online feitos com o e-mail que a cliente informou na conversa.',
        parameters: { type: 'object', additionalProperties: false, required: ['email'],
                      properties: { email: { type: 'string', description: 'E-mail da compra, exatamente como a cliente escreveu.' },
                                    numero: { type: 'string', description: 'Número do pedido, se a cliente disse (ex.: 12345).' } } }
      } }
    end

    # --- Estoque ---

    def stock(product_text, size)
      tokens = product_text.to_s.downcase.scan(/[[:alnum:]]+/).reject { |t| t.size < 2 }.first(6)
      return { erro: 'Informe qual produto a cliente quer.' } if tokens.empty?

      variants = search_products(tokens)
      if size.present?
        wanted = size.to_s.strip.upcase
        variants = variants.select { |p| [p.option1, p.option2, p.option3].compact.any? { |o| o.strip.upcase == wanted } }
      end
      return { encontrado: false, mensagem: 'Nenhum produto com essa descrição (e tamanho) no catálogo.' } if variants.empty?

      groups = variants.group_by { |p| p.shopify_product_name.presence || p.sku }
      if groups.size > MAX_GROUPS
        return { encontrado: true, varios_produtos: groups.keys.first(8),
                 mensagem: 'Há vários produtos parecidos. Pergunte à cliente qual deles (cor/modelo) antes de dizer onde tem.' }
      end

      levels = available_by_item(variants.first(MAX_VARIANTS).map(&:shopify_inventory_item_id))
      { encontrado: true, tamanho_pedido: size.presence,
        produtos: groups.map { |name, items| product_availability(name, items, levels) } }
    end

    # Todas as palavras precisam aparecer no SKU ou no nome; sem resultado, tenta deixar uma palavra de fora (cor
    # em português, "a", "da" etc.).
    def search_products(tokens)
      base = Product.where.not(shopify_inventory_item_id: [nil, ''])
      [tokens, *tokens.combination(tokens.size - 1).to_a].uniq.each do |words|
        next if words.empty?

        found = words.reduce(base) { |scope, t| scope.where('LOWER(sku) LIKE :q OR LOWER(shopify_product_name) LIKE :q', q: "%#{t}%") }
                     .order(:shopify_product_name, :sku).limit(200).to_a
        return found if found.any?
      end
      []
    end

    def product_availability(name, items, levels)
      stores = Hash.new { |h, k| h[k] = [] }
      items.each do |item|
        Array(levels[item.shopify_inventory_item_id.to_s]).each do |store|
          stores[store] << (item.option1.presence || item.sku)
        end
      end
      { nome: name,
        disponivel_em: stores.map { |store, sizes| { loja: store, tamanhos: sizes.uniq } },
        sem_estoque_em_lugar_nenhum: stores.empty? }
    end

    # { inventory_item_id => [nome da loja com estoque > 0] }
    def available_by_item(item_ids)
      ids = item_ids.compact.uniq.map { |id| id.to_s.start_with?('gid://') ? id : "gid://shopify/InventoryItem/#{id}" }
      return {} if ids.empty?

      body = graphql(<<~GRAPHQL, { ids: ids })
        query($ids: [ID!]!) {
          nodes(ids: $ids) {
            ... on InventoryItem {
              id
              inventoryLevels(first: 30) { nodes { location { id name isActive } quantities(names: ["available"]) { quantity } } }
            }
          }
        }
      GRAPHQL
      names = store_names
      Array(body.dig('data', 'nodes')).compact.to_h do |node|
        stores = Array(node.dig('inventoryLevels', 'nodes')).filter_map do |level|
          next unless level.dig('location', 'isActive') != false
          next unless Array(level['quantities']).sum { |q| q['quantity'].to_i }.positive?

          location_id = level.dig('location', 'id').to_s.split('/').last
          names[location_id] || level.dig('location', 'name')
        end
        [node['id'].to_s.split('/').last, stores]
      end
    end

    def store_names
      Location.where.not(shopify_location_id: [nil, '']).to_h do |l|
        [l.shopify_location_id.to_s, l.slug == ONLINE_SLUG ? 'Site (envio para casa)' : l.name]
      end
    end

    # --- Pedidos ---

    def orders(email, number)
      email = email.to_s.strip.downcase
      return { erro: 'E-mail inválido. Peça o e-mail usado na compra.' } unless email.match?(EMAIL)
      unless client_texts.include?(email)
        return { erro: 'A cliente ainda não escreveu esse e-mail na conversa. Peça o e-mail usado na compra.' }
      end

      body = graphql(<<~GRAPHQL, { q: "email:#{email}" })
        query($q: String!) {
          orders(first: 10, sortKey: CREATED_AT, reverse: true, query: $q) {
            nodes {
              name createdAt cancelledAt email displayFinancialStatus displayFulfillmentStatus
              totalPriceSet { shopMoney { amount } }
              lineItems(first: 10) { nodes { name quantity } }
              fulfillments(first: 5) { displayStatus trackingInfo(first: 3) { number url company } }
            }
          }
        }
      GRAPHQL
      found = Array(body.dig('data', 'orders', 'nodes')).select { |o| o['email'].to_s.downcase == email }
      digits = number.to_s.gsub(/\D/, '')
      found = found.select { |o| o['name'].to_s.gsub(/\D/, '') == digits } if digits.present?
      return { encontrado: false, mensagem: 'Nenhum pedido com esse e-mail' + (digits.present? ? " e número #{digits}." : '.') } if found.empty?

      { encontrado: true, pedidos: found.first(5).map { |o| order_summary(o) } }
    end

    def order_summary(order)
      tracking = Array(order['fulfillments']).flat_map do |f|
        Array(f['trackingInfo']).map { |t| { situacao: SHIPMENT[f['displayStatus']] || f['displayStatus'].to_s.downcase.tr('_', ' '), codigo: t['number'], link: t['url'], transportadora: t['company'] }.compact }
      end
      { numero: order['name'], feito_em: Time.zone.parse(order['createdAt'].to_s)&.strftime('%d/%m/%Y'),
        cancelado: order['cancelledAt'].present?,
        pagamento: FINANCIAL[order['displayFinancialStatus']] || order['displayFinancialStatus'].to_s.downcase,
        envio: FULFILLMENT[order['displayFulfillmentStatus']] || order['displayFulfillmentStatus'].to_s.downcase,
        total: order.dig('totalPriceSet', 'shopMoney', 'amount'),
        itens: Array(order.dig('lineItems', 'nodes')).map { |i| "#{i['quantity']}x #{i['name']}" },
        rastreio: tracking }
    end

    def client_texts
      @client_texts ||= @history.select { |m| m[:from] == 'cliente' }.map { |m| m[:text].to_s.downcase }.join("\n")
    end

    def graphql(query, variables)
      return @graphql.call(query, variables) if @graphql

      session = ShopifyAPI::Auth::Session.new(shop: SHOP, access_token: ENV.fetch('CHASE_ORDERS_TOKEN'))
      ShopifyAPI::Clients::Graphql::Admin.new(session: session).query(query: query, variables: variables).body
    end
  end
end
