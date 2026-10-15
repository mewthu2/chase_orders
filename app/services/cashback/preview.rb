# frozen_string_literal: true

module Cashback
  class Preview
    class Error < StandardError; end

    def initialize(gateway: ShopifyGateway.new)
      @gateway = gateway
    end

    def call(codes:, customer:, ownership_confirmed:)
      codes = Array(codes).map { |code| code.to_s.strip.upcase }
      unless codes.size == 2 && codes.uniq.size == 2 && codes.all? { |code| code.match?(/\AMTZ[A-Z0-9_-]{1,252}\z/) }
        raise Error, 'Informe dois cupons MTZ diferentes.'
      end
      unless customer&.shopify_customer_id.to_s.match?(/\A[1-9]\d*\z/)
        raise Error, 'Selecione uma cliente com cadastro na Shopify.'
      end

      gid = "gid://shopify/Customer/#{customer.shopify_customer_id}"
      sources = codes.map do |code|
        node = @gateway.lookup(code)
        raise Error, "Cupom #{code} não encontrado na Shopify." unless node
        validate!(node, code, gid, ownership_confirmed)
        { 'code' => code, 'node_id' => node.fetch('id'), 'data' => node.fetch('codeDiscount') }
      end
      raise Error, 'Os códigos pertencem ao mesmo desconto.' unless sources.map { |source| source['node_id'] }.uniq.size == 2
      if sources.map { |source| source['data']['combinesWith'] }.uniq.size != 1
        raise Error, 'Os cupons têm regras diferentes de combinação com outros descontos.'
      end

      {
        customer: customer, customer_gid: gid, source_snapshots: sources,
        amount: sources.sum { |source| money(source['data'].dig('customerGets', 'value', 'amount')) },
        minimum_purchase: sources.sum { |source| money(source['data'].dig('minimumRequirement', 'greaterThanOrEqualToSubtotal')) },
        expires_at: sources.map { |source| Time.iso8601(source['data']['endsAt']) }.min,
        ownership_confirmed: ownership_confirmed == true
      }
    end

    private

    def validate!(node, code, customer_gid, ownership_confirmed)
      data = node.fetch('codeDiscount')
      raise Error, "#{code}: somente cashback de valor fixo pode ser unificado." unless data['__typename'] == 'DiscountCodeBasic'
      unless data['status'] == 'ACTIVE' && Time.iso8601(data.fetch('startsAt')) <= Time.current &&
             data['endsAt'].present? && Time.iso8601(data['endsAt']) > Time.current
        raise Error, "#{code}: o cupom precisa estar ativo e dentro da validade."
      end
      raise Error, "#{code}: o cupom já foi utilizado." unless data['asyncUsageCount'] == 0
      raise Error, "#{code}: somente cupons de uso único podem ser unificados." unless data['usageLimit'] == 1
      redeem_codes = data.fetch('codes')
      unless redeem_codes.dig('pageInfo', 'hasNextPage') == false && redeem_codes['nodes'].size == 1 &&
             redeem_codes['nodes'].first['code'].casecmp?(code)
        raise Error, "#{code}: descontos com vários códigos não podem ser unificados."
      end
      gets = data.fetch('customerGets')
      unless gets.dig('items', '__typename') == 'AllDiscountItems' && gets.dig('value', '__typename') == 'DiscountAmount' &&
             gets.dig('value', 'appliesOnEachItem') == false && gets['appliesOnSubscription'] == false &&
             gets['appliesOnOneTimePurchase'] == true
        raise Error, "#{code}: o cashback precisa ser de valor fixo para a compra, sem restrição de produtos ou assinatura."
      end
      money(gets.dig('value', 'amount'))
      unless data.dig('minimumRequirement', '__typename') == 'DiscountMinimumSubtotal'
        raise Error, "#{code}: o cupom precisa ter um valor mínimo de compra."
      end
      money(data.dig('minimumRequirement', 'greaterThanOrEqualToSubtotal'))
      context = data.fetch('context')
      case context['__typename']
      when 'DiscountCustomers'
        unless context.fetch('customers').map { |customer| customer['id'] } == [customer_gid]
          raise Error, "#{code}: o cupom não pertence exclusivamente à cliente selecionada."
        end
      when 'DiscountBuyerSelectionAll'
        unless ownership_confirmed == true
          raise Error, 'Confirme que conferiu que os dois cupons pertencem à cliente selecionada.'
        end
      else
        raise Error, "#{code}: cupons de segmentos ou de outros públicos não podem ser unificados."
      end
      combinations = data.fetch('combinesWith')
      unless %w[orderDiscounts productDiscounts shippingDiscounts].all? { |key| [true, false].include?(combinations[key]) }
        raise Error, 'A Shopify não informou todas as regras de combinação.'
      end
    rescue KeyError, ArgumentError, TypeError
      raise Error, "#{code}: dados incompletos ou inválidos na Shopify."
    end

    def money(value)
      amount = BigDecimal(value.fetch('amount'))
      unless value['currencyCode'] == 'BRL' && amount.finite? && amount.positive? && amount == amount.round(2)
        raise Error, 'Os valores de cashback e compra mínima precisam ser positivos, em reais e com até dois decimais.'
      end
      amount
    rescue KeyError, ArgumentError, TypeError, NoMethodError
      raise Error, 'Valor de cashback ou mínimo de compra inválido.'
    end
  end
end
