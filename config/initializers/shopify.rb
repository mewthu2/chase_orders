ShopifyAPI::Context.setup(
  api_key: ENV.fetch('SHOPIFY_API_KEY'),
  api_secret_key: ENV.fetch('SHOPIFY_API_SECRET'),
  scope: "read_orders,read_products",
  is_embedded: true,
  api_version: "2023-10",
  is_private: true,
)