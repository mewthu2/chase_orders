class SyncProductsSituationJob < ActiveJob::Base
  def perform(kind)
    sync_tiny_products
    sync_shopify_products
  end

  def sync_tiny_products
    Tiny::Products.list_all_products('', 'update_products_situation', '')
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end
end
