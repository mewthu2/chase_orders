ShopifyAPI::Context.setup(
  api_key: ENV.fetch('SHOPIFY_API_KEY'),
  api_secret_key: ENV.fetch('SHOPIFY_API_SECRET'),
  scope: "create_orders, read_orders,read_products,read_variants",
  is_embedded: true,
  api_version: "2025-01",
  is_private: true,
)