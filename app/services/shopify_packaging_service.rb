# frozen_string_literal: true

class ShopifyPackagingService
  BOX_SMALL_VARIANT_ID = 42631324500042
  BOX_LARGE_VARIANT_ID = 42631324532810

  BOX_P_VOLUME = 500
  BOX_G_VOLUME = 1000

  DISCOUNT_SMALL = 10.0
  DISCOUNT_LARGE = 20.0

  def initialize(order_id)
    @order_id = order_id
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )
    @graphql = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
    @rest = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def run
    Rails.logger.info "📦 [ShopifyPackagingService] Iniciando cálculo para o pedido #{@order_id}"
    order = fetch_order
    return { success: false, message: 'Pedido não encontrado' } unless order

    cart_items = extract_line_items(order)
    boxes = calculate_boxes(cart_items)

    Rails.logger.info "📦 Calculado: #{boxes[:small]} pequenas, #{boxes[:large]} grandes"
    update_order_boxes(order, boxes)

    apply_discount(order, boxes)

    { success: true, message: 'Cálculo, atualização e desconto aplicados com sucesso', boxes: boxes }
  rescue StandardError => e
    Rails.logger.error "❌ Erro em ShopifyPackagingService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, message: e.message }
  end

  private

  def fetch_order
    query = <<~GRAPHQL
      query getOrder($id: ID!) {
        order(id: $id) {
          id
          name
          lineItems(first: 100) {
            edges {
              node {
                id
                name
                quantity
                variant {
                  id
                  sku
                  product {
                    id
                    title
                    metafields(first: 10, namespace: "custom") {
                      edges {
                        node {
                          key
                          value
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    gid = "gid://shopify/Order/#{@order_id}"
    response = @graphql.query(query: query, variables: { id: gid })

    if response.body['errors']
      Rails.logger.error "GraphQL errors: #{response.body['errors']}"
      return nil
    end

    order = response.body.dig('data', 'order')
    Rails.logger.info "✅ Pedido encontrado: #{order['name']}"
    order
  end

  def extract_line_items(order)
    order.dig('lineItems', 'edges').map do |edge|
      node = edge['node']
      product = node.dig('variant', 'product')
      metafields = product.dig('metafields', 'edges') || []

      metafield_hash = metafields.each_with_object({}) do |m, acc|
        acc[m.dig('node', 'key')] = m.dig('node', 'value')
      end

      {
        variant_id: node.dig('variant', 'id'),
        sku: node.dig('variant', 'sku'),
        title: node['name'],
        quantity: node['quantity'],
        volume: metafield_hash['volume']&.to_i || 100,
        tipo_de_embalagem: metafield_hash['tipo_de_embalagem']
      }
    end
  end

  def calculate_boxes(cart_items)
    boxes_p = 0
    boxes_g = 0
    force_small = []
    force_large = []
    normal_products = Hash.new(0)

    cart_items.each do |item|
      tipo = item[:tipo_de_embalagem]
      vol = item[:volume]
      qty = item[:quantity]

      case tipo
      when 'A'
        force_small << { volume: vol, quantity: qty }
      when 'B'
        force_large << { volume: vol, quantity: qty }
      else
        normal_products[vol] += qty
      end
    end

    force_small.each do |item|
      per_box = (BOX_P_VOLUME / item[:volume]).floor
      boxes_p += (item[:quantity].to_f / per_box).ceil
    end

    force_large.each do |item|
      per_box = (BOX_G_VOLUME / item[:volume]).floor
      boxes_g += (item[:quantity].to_f / per_box).ceil
    end

    normal_products.each do |volume, qty|
      per_p = (BOX_P_VOLUME / volume).floor
      per_g = (BOX_G_VOLUME / volume).floor
      remaining = qty

      while remaining > per_p
        boxes_g += 1
        remaining -= per_g
      end

      boxes_p += (remaining.to_f / per_p).ceil if remaining > 0
    end

    { small: boxes_p, large: boxes_g }
  end

  def update_order_boxes(order, boxes)
    updates = []
    updates << { variant_id: BOX_SMALL_VARIANT_ID, quantity: boxes[:small] } if boxes[:small].positive?
    updates << { variant_id: BOX_LARGE_VARIANT_ID, quantity: boxes[:large] } if boxes[:large].positive?

    return if updates.empty?

    Rails.logger.info "🧾 Atualizando pedido com embalagens: #{updates.to_json}"

    begin
      mutation_begin = <<~GRAPHQL
        mutation beginEdit($orderId: ID!) {
          orderEditBegin(id: $orderId) {
            calculatedOrder {
              id
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      response_begin = @graphql.query(query: mutation_begin, variables: { orderId: order['id'] })
      edit_id = response_begin.body.dig('data', 'orderEditBegin', 'calculatedOrder', 'id')

      return unless edit_id

      updates.each do |item|
        mutation_add = <<~GRAPHQL
          mutation addVariant($editId: ID!, $variantId: ID!, $quantity: Int!) {
            orderEditAddVariant(id: $editId, variantId: $variantId, quantity: $quantity) {
              userErrors { message }
            }
          }
        GRAPHQL

        gid_variant = "gid://shopify/ProductVariant/#{item[:variant_id]}"
        @graphql.query(
          query: mutation_add,
          variables: { editId: edit_id, variantId: gid_variant, quantity: item[:quantity] }
        )
      end

      mutation_commit = <<~GRAPHQL
        mutation commitEdit($editId: ID!) {
          orderEditCommit(id: $editId, notifyCustomer: false, staffNote: "Embalagem adicionada automaticamente") {
            userErrors { message }
          }
        }
      GRAPHQL

      @graphql.query(query: mutation_commit, variables: { editId: edit_id })
    rescue StandardError => e
      Rails.logger.error "❌ Erro geral em update_order_boxes: #{e.message}"
    end
  end

  # ==========================================
  # == APLICA DESCONTO CONFORME EMBALAGEM ==
  # ==========================================
  def apply_discount(order, boxes)
    total_discount = (boxes[:small] * DISCOUNT_SMALL) + (boxes[:large] * DISCOUNT_LARGE)
    return if total_discount <= 0

    Rails.logger.info "💰 Aplicando desconto de R$ #{total_discount.round(2)} no pedido #{order['name']}"

    begin
      mutation_discount = <<~GRAPHQL
        mutation discountAdd($orderId: ID!, $amount: Money!) {
          orderDiscountCodeApplyManual(
            orderId: $orderId,
            discountCode: "DESCONTO_EMBALAGEM",
            amount: $amount
          ) {
            order { id name }
            userErrors { field message }
          }
        }
      GRAPHQL

      @graphql.query(
        query: mutation_discount,
        variables: { orderId: order['id'], amount: total_discount.to_f }
      )
    rescue StandardError => e
      Rails.logger.error "❌ Erro ao aplicar desconto: #{e.message}"
    end
  end
end
