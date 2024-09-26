class SyncProductsSituationJob < ActiveJob::Base
  def perform
    sync_tiny_products('lagoa_seca')
    sync_tiny_products('bh_shopping')
    sync_tiny_product_stock
    sync_shopify_products
  end

  def sync_tiny_products(kind)
    Tiny::Products.list_all_products(kind, 'A', 'update_products_situation', '')
  end

  def sync_shopify_products
    Shopify::Products.list_all_products('create_update_shopify_products')
  end

  def sync_tiny_product_stock
    Tiny::Products.assert_stock
  end
end
