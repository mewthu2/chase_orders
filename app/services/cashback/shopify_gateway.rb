# frozen_string_literal: true

module Cashback
  # Separate version so this feature does not change the other Shopify integrations.
  class ShopifyGateway
    API_VERSION = '2026-07'
    class Error < StandardError; end

    LOOKUP = <<~GRAPHQL
      query CashbackCoupon($code: String!) {
        codeDiscountNodeByCode(code: $code) {
          id
          codeDiscount {
            __typename
            ... on DiscountCodeBasic {
              title status startsAt endsAt asyncUsageCount usageLimit appliesOncePerCustomer
              codes(first: 2) { nodes { code } pageInfo { hasNextPage } }
              context { __typename ... on DiscountCustomers { customers { id } } }
              combinesWith { orderDiscounts productDiscounts shippingDiscounts }
              customerGets {
                appliesOnOneTimePurchase appliesOnSubscription
                items { __typename }
                value {
                  __typename
                  ... on DiscountAmount { amount { amount currencyCode } appliesOnEachItem }
                }
              }
              minimumRequirement {
                __typename
                ... on DiscountMinimumSubtotal { greaterThanOrEqualToSubtotal { amount currencyCode } }
              }
            }
          }
        }
      }
    GRAPHQL

    DEACTIVATE = <<~GRAPHQL
      mutation DeactivateCashback($id: ID!) {
        discountCodeDeactivate(id: $id) {
          codeDiscountNode { id }
          userErrors { field message }
        }
      }
    GRAPHQL

    CREATE = <<~GRAPHQL
      mutation CreateUnifiedCashback($input: DiscountCodeBasicInput!) {
        discountCodeBasicCreate(basicCodeDiscount: $input) {
          codeDiscountNode { id }
          userErrors { field message }
        }
      }
    GRAPHQL

    def lookup(code)
      execute(LOOKUP, code: code).fetch('codeDiscountNodeByCode')
    end

    def deactivate(id)
      mutate(DEACTIVATE, 'discountCodeDeactivate', id: id)
    end

    def create(input)
      mutate(CREATE, 'discountCodeBasicCreate', input: input)
    end

    private

    def mutate(query, field, variables)
      result = execute(query, variables).fetch(field)
      raise Error, 'Resposta incompleta da Shopify.' unless result.is_a?(Hash) && result['userErrors'].is_a?(Array)
      if result['userErrors'].any?
        raise Error, result['userErrors'].map { |error| error['message'] }.join('; ')
      end

      result.dig('codeDiscountNode', 'id').presence || raise(Error, 'Shopify não confirmou a alteração do cupom.')
    end

    def execute(query, variables)
      response = HTTParty.post(
        "https://chasebrasil.myshopify.com/admin/api/#{API_VERSION}/graphql.json",
        headers: { 'X-Shopify-Access-Token' => ENV.fetch('CHASE_ORDERS_TOKEN'), 'Content-Type' => 'application/json' },
        body: { query: query, variables: variables }.to_json,
        timeout: 15
      )
      raise Error, "Shopify indisponível (HTTP #{response.code})." unless response.success?

      body = response.parsed_response
      raise Error, 'Resposta inválida da Shopify.' unless body.is_a?(Hash)
      raise Error, body['errors'].map { |error| error['message'] }.join('; ') if body['errors'].present?

      body['data'].presence || raise(Error, 'Resposta da Shopify sem dados.')
    rescue KeyError, JSON::ParserError
      raise Error, 'Resposta incompleta da Shopify.'
    end
  end
end
