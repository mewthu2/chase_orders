class DanielJob < ActiveJob::Base
  queue_as :default

  def perform
    Tiny::Orders.get_all_orders('bh_shopping', 'Entregue', 'update_orders', '')
  end

  def list_all_unused_discounts_until_date(session:, date:, only_active: true)
    query = <<~GRAPHQL
      query($query: String!, $after: String) {
        discountNodes(first: 50, query: $query, after: $after, sortKey: CREATED_AT) {
          pageInfo {
            hasNextPage
            endCursor
          }
          edges {
            node {
              id
              discount {
                __typename
                ... on DiscountCodeBasic {
                  title
                  startsAt
                  endsAt
                  codes(first: 10) {
                    edges {
                      node {
                        code
                        asyncUsageCount
                      }
                    }
                  }
                }
                ... on DiscountCodeBxgy {
                  title
                  startsAt
                  endsAt
                  codes(first: 10) {
                    edges {
                      node {
                        code
                        asyncUsageCount
                      }
                    }
                  }
                }
                ... on DiscountCodeFreeShipping {
                  title
                  startsAt
                  endsAt
                  codes(first: 10) {
                    edges {
                      node {
                        code
                        asyncUsageCount
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

    filter_query = "created_at:<=#{date}"
    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)

    all_discounts = []
    after_cursor = nil
    today = Date.today

    loop do
      variables = { query: filter_query, after: after_cursor }
      response = client.query(query:, variables:)

      if response.body['errors']
        puts "Erro ao listar cupons: #{response.body['errors']}"
        break
      end

      discount_nodes = response.body.dig('data', 'discountNodes', 'edges') || []
      page_info = response.body.dig('data', 'discountNodes', 'pageInfo')

      discount_nodes.each do |edge|
        node = edge['node']
        discount = node['discount']

        starts_at = discount['startsAt'] ? Date.parse(discount['startsAt']) : nil
        ends_at = discount['endsAt'] ? Date.parse(discount['endsAt']) : nil

        # filtro de ativos, se solicitado
        if only_active
          next if starts_at && starts_at > today
          next if ends_at && ends_at < today
        end

        codes = discount.dig('codes', 'edges') || []

        unused_codes = codes
          .map { |e| e['node'] }
          .select { |code_node| code_node['asyncUsageCount'].to_i == 0 }

        next if unused_codes.empty?

        all_discounts << {
          id: node['id'],
          type: discount['__typename'],
          title: discount['title'],
          starts_at: discount['startsAt'],
          ends_at: discount['endsAt'],
          codes: unused_codes.map { |code| { code: code['code'], usage_count: 0 } }
        }
      end

      break unless page_info && page_info['hasNextPage']

      after_cursor = page_info['endCursor']
    end

    all_discounts
  end

  def deactivate_unused_discounts_until_date(session:, date:, only_active: true)
    discounts = list_all_unused_discounts_until_date(session:, date:, only_active:)

    puts "Desativando #{discounts.size} cupons não usados até #{date}..."

    mutation = <<~GRAPHQL
      mutation discountDeactivate($id: ID!) {
        discountDeactivate(id: $id) {
          userErrors {
            field
            message
          }
        }
      }
    GRAPHQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)

    errors = []

    discounts.each do |discount|
      response = client.query(query: mutation, variables: { id: discount[:id] })

      user_errors = response.dig('body', 'data', 'discountDeactivate', 'userErrors') || []

      if user_errors.any?
        puts "Erro ao desativar #{discount[:title]} (#{discount[:id]}): #{user_errors}"
        errors << { id: discount[:id], title: discount[:title], errors: user_errors }
      else
        puts "Cupom desativado: #{discount[:title]} (#{discount[:id]})"
      end
    end

    puts "Processo concluído. Total com erro: #{errors.size}"
    errors
  end

  def activate_discounts(session:, discounts:, new_ends_at: nil)
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
    new_ends_at ||= (Date.today + 365).iso8601 # padrão: ativa por mais 1 ano

    discounts.each do |discount|
      discount_id = discount[:id]

      mutation = <<~GRAPHQL
        mutation discountCodeBasicUpdate($id: ID!, $endsAt: DateTime) {
          discountCodeBasicUpdate(id: $id, input: { endsAt: $endsAt }) {
            userErrors {
              field
              message
            }
            discountCodeBasic {
              id
              endsAt
            }
          }
        }
      GRAPHQL

      variables = {
        id: discount_id,
        endsAt: new_ends_at
      }

      response = client.query(query: mutation, variables: variables)

      errors = response.body.dig('data', 'discountCodeBasicUpdate', 'userErrors')
      if errors.any?
        puts "Erro ao ativar cupom #{discount_id}: #{errors.map { |e| e['message'] }.join(', ')}"
      else
        puts "Cupom #{discount_id} ativado com endsAt=#{new_ends_at}"
      end
    end
  end

end