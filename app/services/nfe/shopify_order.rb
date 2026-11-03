module Nfe
  # Pedido da Shopify lido na hora da emissão, já no formato que a nota precisa: destinatário (pré-preenchido com
  # o que o checkout grava nos atributos do pedido), itens com desconto, frete e forma de pagamento.
  class ShopifyOrder
    class NotFound < StandardError; end

    QUERY = <<~GRAPHQL.freeze
      query NfeOrder($query: String!) {
        orders(first: 1, query: $query) {
          nodes {
            legacyResourceId
            name
            createdAt
            cancelledAt
            displayFinancialStatus
            email
            phone
            paymentGatewayNames
            shippingAddress { name company address1 address2 city provinceCode zip phone }
            billingAddress { name company address1 address2 city provinceCode zip phone }
            localizedFields(first: 10) { nodes { key value } }
            customAttributes { key value }
            lineItems(first: 100) {
              nodes {
                sku
                name
                quantity
                currentQuantity
                originalUnitPriceSet { shopMoney { amount } }
                discountAllocations { allocatedAmountSet { shopMoney { amount } } }
              }
            }
            shippingLines(first: 10) { nodes { title discountedPriceSet { shopMoney { amount } } } }
          }
        }
      }
    GRAPHQL

    # Rótulos das formas de pagamento da NF-e (tPag) oferecidas na tela.
    PAYMENT_METHODS = {
      '03' => 'Cartão de crédito', '04' => 'Cartão de débito', '17' => 'PIX', '15' => 'Boleto',
      '01' => 'Dinheiro', '99' => 'Outros'
    }.freeze
    PAID_STATUSES = %w[PAID PARTIALLY_REFUNDED].freeze

    attr_reader :node

    # Aceita o número do pedido ("1234" ou "#1234") ou o id numérico da Shopify.
    def self.find(reference)
      ref = reference.to_s.strip
      raise NotFound, 'Informe o número do pedido.' if ref.blank?

      query = ref.delete('#').match?(/\A\d{9,}\z/) ? "id:#{ref.delete('#')}" : "name:##{ref.delete('#')}"
      node = fetch_node(query)
      raise NotFound, "Pedido #{ref} não encontrado na Shopify." unless node

      new(node)
    end

    def self.fetch_node(query)
      session = ShopifyAPI::Auth::Session.new(shop: 'chasebrasil.myshopify.com', access_token: ENV.fetch('CHASE_ORDERS_TOKEN'))
      response = ShopifyAPI::Clients::Graphql::Admin.new(session:).query(query: QUERY, variables: { query: query })
      errors = response.body['errors']
      raise NotFound, "Shopify: #{Array(errors).map { |e| e['message'] }.join('; ')}" if errors.present?

      response.body.dig('data', 'orders', 'nodes', 0)
    end

    def initialize(node)
      @node = node
    end

    def name
      node['name']
    end

    def shopify_id
      node['legacyResourceId'].to_s
    end

    def created_at
      Time.zone.parse(node['createdAt'].to_s)
    end

    def local_order
      @local_order ||= Order.find_by(shopify_order_id: shopify_id)
    end

    def financial_status
      node['displayFinancialStatus']
    end

    def attributes
      @attributes ||= Array(node['customAttributes']).to_h { |a| [a['key'], a['value']] }
    end

    # Venda de loja física: o PDV (Iglu) já emitiu NFC-e.
    def nfce_key
      attributes['nfce-key'].presence
    end

    def document
      localized = Array(node.dig('localizedFields', 'nodes')).find { |f| f['key'].to_s.start_with?('TAX_CREDENTIAL_BR') }
      raw = attributes['additional_cpf_cnpj'].presence || attributes['info_document'].presence ||
            attributes['customer_document'].presence || localized&.dig('value')
      Cnpj.digits(raw)
    end

    # Destinatário pré-preenchido: a tela deixa conferir e corrigir antes de emitir.
    def recipient
      address = node['shippingAddress'] || node['billingAddress'] || {}
      zip = Cnpj.digits(address['zip'])
      ibge = Ibge.lookup(zip)
      {
        name: address['name'].presence || attributes['customer_name'],
        document: document,
        ie_indicator: 9,
        street: attributes['shipping_street_name'].presence || address['address1'],
        number: attributes['shipping_street_number'].presence || 'S/N',
        complement: attributes['shipping_street_complement'].presence,
        neighbourhood: attributes['shipping_neighborhood'].presence || ibge&.dig(:neighbourhood).presence || address['address2'],
        city: ibge&.dig(:city).presence || attributes['shipping_city'].presence || address['city'],
        city_ibge_code: ibge&.dig(:ibge),
        state: (attributes['shipping_province'].presence || address['provinceCode']).to_s.upcase,
        zip: zip,
        phone: address['phone'].presence || node['phone'].presence || attributes['customer_phone_number'],
        email: node['email'].presence || attributes['customer_email']
      }
    end

    def items
      Array(node.dig('lineItems', 'nodes')).filter_map do |line|
        quantity = line['currentQuantity'].to_i
        next if quantity.zero?

        discount = Array(line['discountAllocations']).sum { |d| money(d.dig('allocatedAmountSet', 'shopMoney', 'amount')) }
        # Desconto vem para a quantidade original; numa devolução parcial fica proporcional ao que sobrou.
        discount = (discount * quantity / [line['quantity'].to_i, 1].max).round(2)
        { sku: line['sku'].to_s, name: line['name'], quantity: quantity,
          unit_price: money(line.dig('originalUnitPriceSet', 'shopMoney', 'amount')), discount: discount }
      end
    end

    def freight
      Array(node.dig('shippingLines', 'nodes')).sum { |l| money(l.dig('discountedPriceSet', 'shopMoney', 'amount')) }
    end

    def products_total
      items.sum { |i| i[:unit_price] * i[:quantity] }
    end

    def discount_total
      items.sum { |i| i[:discount] }
    end

    def total
      products_total - discount_total + freight
    end

    # Forma de pagamento sugerida a partir do que o checkout grava (payment_type/payment_method).
    def payment
      type = attributes['payment_type'].to_s
      method = attributes['payment_method'].to_s.downcase
      gateways = Array(node['paymentGatewayNames']).join(' ').downcase
      code =
        if method == 'pix' || gateways.include?('pix') then '17'
        elsif type == 'credit_card' then '03'
        elsif type == 'debit_card' then '04'
        elsif type == 'ticket' || method.include?('bol') || gateways.include?('boleto') then '15'
        else '99'
        end
      { method: code, installments: [attributes['payment_installment'].to_i, 1].max,
        description: (gateways.presence || method.presence || 'Outros').first(60) }
    end

    # Avisos para a tela; o que impede a emissão vem em blocking_issues.
    def warnings
      list = []
      list << "Pedido com status financeiro #{financial_status}." unless PAID_STATUSES.include?(financial_status)
      list << 'Pedido sem frete cobrado.' if freight.zero?
      list
    end

    def blocking_issues
      list = []
      list << 'Pedido cancelado na Shopify.' if node['cancelledAt'].present?
      list << "Venda de loja física: o PDV já emitiu a NFC-e #{nfce_key}." if nfce_key
      list << 'Pedido sem itens a faturar.' if items.empty?
      list
    end

    private

    def money(value)
      BigDecimal((value.presence || 0).to_s)
    end
  end
end
