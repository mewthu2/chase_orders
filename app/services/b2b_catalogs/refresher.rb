# Atualiza o disponível (Correios B2B − reservas da fila) e as fotos (Shopify) dos catálogos ativos.
# Roda de hora em hora (rake b2b_catalogs:refresh) e logo depois de salvar um catálogo.
module B2bCatalogs
  class Refresher
    def self.call(catalog_ids = nil) = new(catalog_ids).call

    def initialize(catalog_ids)
      scope = B2bCatalog.active
      scope = scope.where(id: catalog_ids) if catalog_ids.present?
      @catalog_ids = scope.pluck(:id)
    end

    def call
      return if @catalog_ids.empty?

      products = B2bCatalogProduct.where(b2b_catalog_id: @catalog_ids)
      refresh_stock(B2bCatalogVariant.where(b2b_catalog_product_id: products.select(:id)).distinct.pluck(:sku))
      refresh_images(products.where.not(shopify_product_id: [nil, '']).distinct.pluck(:shopify_product_id))
      B2bCatalog.where(id: @catalog_ids).update_all(stock_refreshed_at: Time.current)
    end

    private

    def refresh_stock(skus)
      stocks = B2bStockAvailability.correios_stocks(skus)

      skus.each do |sku|
        result = B2bStockAvailability.build(sku, stocks[sku])
        next if result.error?

        level = B2bCatalogVariant.availabilities[B2bCatalogVariant.availability_for(result.available)]
        B2bCatalogVariant.where(sku:).update_all(available: result.available, availability: level, updated_at: Time.current)
      end
    end

    def refresh_images(shopify_product_ids)
      shopify_product_ids.each do |shopify_product_id|
        urls = ShopifyImages.fetch(shopify_product_id)
        next if urls.empty?

        B2bCatalogProduct.where(shopify_product_id:).update_all(image_urls: urls, updated_at: Time.current)
      end
    end
  end
end
