class B2bCatalogRefreshJob < ActiveJob::Base
  queue_as :default

  def perform(catalog_id = nil)
    B2bCatalogs::Refresher.call(catalog_id.presence && [catalog_id])
  end
end
