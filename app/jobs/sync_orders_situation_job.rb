class SyncOrdersSituationJob < ActiveJob::Base
  def perform
    # sync_shopify_products
    sync_shopify_fields
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_shopify_fields
    Shopify::Products.sync_shopify_data_on_product('shopify_product_id')
    Shopify::Products.sync_shopify_data_on_product('price_and_title')
  end
end
