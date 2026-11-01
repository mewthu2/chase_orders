# frozen_string_literal: true

require 'uri'

module Whatsapp
  # Read-only and scoped to the explicitly linked Shopify customer. Never falls
  # back to fuzzy phone/name searches which could expose a different customer's orders.
  class ShopifyCustomerContext
    API_VERSION = '2026-07'
    ENDPOINT = "https://chasebrasil.myshopify.com/admin/api/#{API_VERSION}/graphql.json"
    class Error < StandardError; end

    ORDERS = <<~GRAPHQL
      query WhatsappCustomerOrders($id: ID!, $after: String) {
        customer(id: $id) {
          id
          orders(first: 10, after: $after, sortKey: CREATED_AT, reverse: true) {
            nodes {
              id name createdAt displayFinancialStatus displayFulfillmentStatus
              totalPriceSet { shopMoney { amount currencyCode } }
              lineItems(first: 20) {
                nodes { title quantity }
                pageInfo { hasNextPage }
              }
              fulfillments(first: 10) { trackingInfo(first: 10) { company number url } }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    GRAPHQL

    def orders(customer_id, after: nil)
      id = customer_gid(customer_id)
      unless after.nil? || (after.is_a?(String) && after.bytesize <= 2048)
        raise ArgumentError, 'Página de pedidos inválida. Atualize a consulta.'
      end
      customer = execute(id: id, after: after.presence).fetch('customer')
      raise Error, 'Cliente vinculado não encontrado na Shopify. Confira o vínculo.' if customer.nil?
      raise Error, 'Resposta inválida da Shopify.' unless customer.is_a?(Hash) && customer['id'] == id

      connection = customer.fetch('orders')
      nodes = connection.fetch('nodes')
      raise Error, 'Resposta incompleta da Shopify.' unless nodes.is_a?(Array)

      { orders: nodes.map { |order| order_payload(order) }, page_info: page_info(connection.fetch('pageInfo')) }
    rescue KeyError, TypeError, NoMethodError
      raise Error, 'Resposta incompleta da Shopify. Tente novamente.'
    end

    private

    def customer_gid(value)
      value = value.to_s
      match = value.match(/\A(?:gid:\/\/shopify\/Customer\/)?([1-9]\d{0,19})\z/)
      raise Error, 'O cadastro vinculado não possui um identificador válido da Shopify. Confira o vínculo.' unless match

      "gid://shopify/Customer/#{match[1]}"
    end

    def execute(variables)
      token = ENV['CHASE_ORDERS_TOKEN'].presence
      raise Error, 'A consulta de pedidos da Shopify não está configurada.' unless token

      response = HTTParty.post(ENDPOINT,
        headers: { 'X-Shopify-Access-Token' => token, 'Content-Type' => 'application/json' },
        body: { query: ORDERS, variables: variables }.to_json, timeout: 15)
      raise Error, 'Não foi possível consultar a Shopify agora. Tente novamente.' unless response.success?

      body = response.parsed_response
      unless body.is_a?(Hash) && body['errors'].blank? && body['data'].is_a?(Hash) && body['data'].key?('customer')
        raise Error, 'A Shopify não concluiu a consulta. Tente novamente ou peça à equipe responsável para conferir o acesso aos pedidos.'
      end
      body['data']
    rescue JSON::ParserError, Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, HTTParty::Error
      raise Error, 'Não foi possível consultar a Shopify agora. Tente novamente.'
    end

    def page_info(value)
      has_next = value.fetch('hasNextPage')
      cursor = value.fetch('endCursor')
      unless [true, false].include?(has_next) && (cursor.nil? || cursor.is_a?(String)) && (!has_next || cursor.present?)
        raise Error, 'Resposta incompleta da Shopify.'
      end
      { has_next_page: has_next, end_cursor: cursor }
    end

    def order_payload(order)
      id = order.fetch('id')
      raise Error, 'Resposta inválida da Shopify.' unless id.is_a?(String) && id.match?(/\Agid:\/\/shopify\/Order\/[1-9]\d*\z/)

      money = order.fetch('totalPriceSet').fetch('shopMoney')
      items = order.fetch('lineItems')
      { id: id, name: order.fetch('name'), created_at: order.fetch('createdAt'),
        total_price: money.fetch('amount'), currency: money.fetch('currencyCode'),
        financial_status: order.fetch('displayFinancialStatus'), fulfillment_status: order.fetch('displayFulfillmentStatus'),
        items: items.fetch('nodes').map { |item| { title: item.fetch('title'), quantity: item.fetch('quantity') } },
        has_more_items: items.fetch('pageInfo').fetch('hasNextPage'),
        tracking: order.fetch('fulfillments').flat_map { |f| f.fetch('trackingInfo') }.map do |tracking|
          { company: tracking['company'], number: tracking['number'], url: safe_url(tracking['url']) }
        end,
        shopify_url: "https://admin.shopify.com/store/chasebrasil/orders/#{id.split('/').last}" }
    end

    def safe_url(value)
      uri = URI.parse(value.to_s)
      value if %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
    rescue URI::InvalidURIError
      nil
    end
  end
end
