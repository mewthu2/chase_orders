# Todas as fotos de um produto do Shopify, na ordem da loja. Falha devolve [] (quem chama mantém as fotos antigas).
module B2bCatalogs
  module ShopifyImages
    module_function

    PAUSE = Rails.env.test? ? 0 : 0.5 # limite da API REST do Shopify (2 req/s)

    def fetch(shopify_product_id)
      response = Shopify::Products.client_shopify_rest.get(path: "products/#{shopify_product_id}.json")
      images = Array(response.body.dig('product', 'images'))
      images.sort_by { |image| image['position'].to_i }.filter_map { |image| image['src'].presence }
    rescue StandardError => e
      Rails.logger.error "B2bCatalogs::ShopifyImages(#{shopify_product_id}): #{e.class} #{e.message}"
      []
    ensure
      sleep(PAUSE)
    end
  end
end
