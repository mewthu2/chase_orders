# frozen_string_literal: true

class CustomerCouponEligibilityService
  def self.eligible_coupons_for(customer)
    new.eligible_coupons_for(customer)
  end

  def initialize
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )
    @client = ShopifyAPI::Clients::Rest::Admin.new(session: @session)
  end

  def eligible_coupons_for(customer)
    customer_gid = "gid://shopify/Customer/#{customer.shopify_customer_id}"

    eligible = []
    segment_candidates = [] # [{ node_id:, discount_data:, segment_ids: [], segment_names: {} }]

    each_code_discount do |node_id, discount_data|
      selection = discount_data['customerSelection']
      next unless selection

      if (customers = selection['customers'])
        if customers.any? { |c| c['id'] == customer_gid }
          eligible << format_coupon(node_id, discount_data, 'Cliente específico')
        end
      elsif (segments = selection['segments'])
        segment_candidates << {
          node_id:,
          discount_data:,
          segment_ids: segments.map { |s| s['id'] },
          segment_names: segments.to_h { |s| [s['id'], s['name']] }
        }
      end
    end

    eligible.concat(eligible_segment_coupons(customer_gid, segment_candidates))
    eligible
  end

  private

  def each_code_discount
    after_cursor = nil

    loop do
      response = @client.post(path: 'graphql.json', body: { query: build_customer_discounts_query(after_cursor) })

      raise StandardError, 'Resposta inválida da API Shopify' unless response.body.is_a?(Hash)

      if response.body['errors']
        raise StandardError, response.body['errors'].map { |e| e['message'] }.join(', ')
      end

      data = response.body.dig('data', 'codeDiscountNodes')
      raise StandardError, 'Dados de cupons não encontrados na resposta da API' unless data

      data['edges'].each do |edge|
        discount = edge.dig('node', 'codeDiscount')
        next unless discount && discount['__typename'] == 'DiscountCodeBasic'

        yield edge.dig('node', 'id'), discount
      end

      page_info = data['pageInfo']
      break unless page_info['hasNextPage']

      after_cursor = page_info['endCursor']
    end
  end

  def eligible_segment_coupons(customer_gid, segment_candidates)
    return [] if segment_candidates.empty?

    all_segment_ids = segment_candidates.flat_map { |c| c[:segment_ids] }.uniq

    response = @client.post(
      path: 'graphql.json',
      body: {
        query: <<~GRAPHQL,
          query CustomerSegmentEligibility($customerId: ID!, $segmentIds: [ID!]!) {
            customerSegmentMembership(customerId: $customerId, segmentIds: $segmentIds) {
              memberships {
                segmentId
                isMember
              }
            }
          }
        GRAPHQL
        variables: { customerId: customer_gid, segmentIds: all_segment_ids }
      }
    )

    raise StandardError, 'Resposta inválida da API Shopify' unless response.body.is_a?(Hash)

    memberships = response.body.dig('data', 'customerSegmentMembership', 'memberships') || []
    member_segment_ids = memberships.select { |m| m['isMember'] }.map { |m| m['segmentId'] }

    segment_candidates.filter_map do |candidate|
      matched_segment_ids = candidate[:segment_ids] & member_segment_ids
      next if matched_segment_ids.empty?

      reason = "Segmento: #{candidate[:segment_names].values_at(*matched_segment_ids).compact.first || 'cliente elegível'}"
      format_coupon(candidate[:node_id], candidate[:discount_data], reason)
    end
  end

  def format_coupon(node_id, discount_data, eligibility_reason)
    code = discount_data.dig('codes', 'nodes', 0, 'code')
    value = discount_data.dig('customerGets', 'value') || {}

    {
      node_id:,
      code:,
      title: discount_data['title'] || code,
      summary: discount_data['summary'],
      status: discount_data['status'],
      starts_at: discount_data['startsAt'],
      ends_at: discount_data['endsAt'],
      usage_limit: discount_data['usageLimit'],
      usage_count: discount_data['asyncUsageCount'],
      discount_type: value['percentage'] ? 'percentage' : 'fixed_amount',
      discount_value: value['percentage'] || value.dig('amount', 'amount'),
      currency_code: value.dig('amount', 'currencyCode'),
      eligibility_reason:
    }
  end

  def build_customer_discounts_query(after_cursor)
    <<~GRAPHQL
      {
        codeDiscountNodes(first: 250, query: "status:active OR status:scheduled"#{after_cursor ? ", after: \"#{after_cursor}\"" : ''}) {
          pageInfo {
            hasNextPage
            endCursor
          }
          edges {
            node {
              id
              codeDiscount {
                __typename
                ... on DiscountCodeBasic {
                  codes(first: 1) {
                    nodes {
                      code
                    }
                  }
                  title
                  summary
                  status
                  startsAt
                  endsAt
                  usageLimit
                  asyncUsageCount
                  customerGets {
                    value {
                      ... on DiscountPercentage {
                        percentage
                      }
                      ... on DiscountAmount {
                        amount {
                          amount
                          currencyCode
                        }
                      }
                    }
                  }
                  customerSelection {
                    ... on DiscountCustomers {
                      customers {
                        id
                      }
                    }
                    ... on DiscountCustomerSegments {
                      segments {
                        id
                        name
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
  end
end
