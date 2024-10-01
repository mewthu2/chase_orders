class SyncOrdersSituationJob < ActiveJob::Base
  def perform
    sync_shopify_products
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end
end
