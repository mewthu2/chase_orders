class ShopifyPaymentCustomizationService
  def initialize
    @session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('CHASE_ORDERS_TOKEN')
    )
  end

  def self.list_customizations
    new.list_customizations
  end

  def list_customizations
    query = <<~GRAPHQL
      {
        paymentCustomizations(first: 20) {
          edges {
            node {
              id
              title
              enabled
              functionId
            }
          }
        }
      }
    GRAPHQL

    client = ShopifyAPI::Clients::Graphql::Admin.new(session: @session)
    response = client.query(query: query)

    if response.body["errors"]
      Rails.logger.error "GraphQL errors: #{response.body["errors"]}"
      return []
    end

    customizations = response.body.dig("data", "paymentCustomizations", "edges") || []

    Rails.logger.info "=== Payment Customizations ==="
    customizations.each do |edge|
      c = edge["node"]
      Rails.logger.info "Title: #{c["title"]}"
      Rails.logger.info "  ID: #{c["id"]}"
      Rails.logger.info "  Function ID (handle): #{c["functionId"]}"
      Rails.logger.info "  Enabled: #{c["enabled"]}"
      Rails.logger.info "----------------------------"
    end

    customizations
  rescue StandardError => e
    Rails.logger.error "Error fetching payment customizations: #{e.message}"
    []
  end
end
