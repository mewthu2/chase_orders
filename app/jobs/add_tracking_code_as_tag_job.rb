class AddTrackingCodeAsTagJob < ActiveJob::Base
  def perform
    session = ShopifyAPI::Auth::Session.new(
      shop: 'dunas-beachwear.myshopify.com',
      access_token: ENV.fetch('SWAP_SHOPIFY_TOKEN')
    )

    five_days_ago = (Date.today - 5.days).to_s

    query = <<~GRAPHQL
      {
        orders(first: 250, query: "created_at:>=#{five_days_ago}", sortKey: CREATED_AT) {
          edges {
            node {
              id
              name
              note
              tags
            }
          }
        }
      }
    GRAPHQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session:)
    response = client.query(query:)
    orders = response.body.dig('data', 'orders', 'edges') || []

    orders.each do |order_edge|
      order = order_edge['node']
      next unless order['note']&.include?('Cód. de Rastreamento:')

      tracking_code = order['note'].match(/Cód\. de Rastreamento:\s*(\S+)/)&.captures&.first
      next unless tracking_code

      current_tags = order['tags'] || []
      next if current_tags.include?(tracking_code)

      new_tags = current_tags + [tracking_code]

      mutation = <<~GRAPHQL
        mutation {
          orderUpdate(input: {
            id: "#{order['id']}",
            tags: #{new_tags.to_json}
          }) {
            order {
              id
              tags
            }
            userErrors {
              field
              message
            }
          }
        }
      GRAPHQL

      update_response = client.query(query: mutation)
      if update_response.body['errors'] || update_response.body.dig('data', 'orderUpdate', 'userErrors')&.any?
        puts "Erro ao atualizar pedido #{order['name']}: #{update_response.body['errors'] || update_response.body.dig('data', 'orderUpdate', 'userErrors')}"
      else
        puts "Tag #{tracking_code} adicionada ao pedido #{order['name']}"
      end
    end
  rescue StandardError => e
    puts "Erro ao processar job: #{e.message}"
    raise e
  end
end