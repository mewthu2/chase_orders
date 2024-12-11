class SyncProductsSituationJob < ActiveJob::Base
  def perform
    sync_tiny_products

    sync_shopify_products
    sync_shopify_fields
  end

  def sync_tiny_products
    Tiny::Products.list_all_products('lagoa_seca', '', 'update_products_situation', '')
    Tiny::Products.list_all_products('rj', '', 'update_products_situation', '')
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_shopify_fields
    Shopify::Products.sync_shopify_data_on_product('shopify_product_id')
    Shopify::Products.sync_shopify_data_on_product('price_and_title')
  end
end
