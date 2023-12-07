class Shopify::Orders
  require 'shopify_api'

  def self.create_order
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('SHOPIFY_TOKEN'),
      scope: 'orders'
    )
    order = ShopifyAPI::Order.new(session:)
    order.line_items = [
      {
        title: 'Big Brown Bear Boots',
        price: 74.99,
        grams: '1300',
        quantity: 3,
        tax_lines: [
          {
            price: 13.5,
            rate: 0.06,
            title: 'State tax'
          }
        ]
      }
    ]
    order.transactions = [
      {
        kind: 'sale',
        status: 'success',
        amount: 238.47
      }
    ]
    order.total_tax = 13.5
    order.currency = 'BRL'
    order.save!
  end

  def self.find_order
    session = ShopifyAPI::Auth::Session.new(
      shop: 'chasebrasil.myshopify.com',
      access_token: ENV.fetch('SHOPIFY_TOKEN')
    )

    ShopifyAPI::Order.find(
      session:,
      id: 5115483652170
    )
  end
end