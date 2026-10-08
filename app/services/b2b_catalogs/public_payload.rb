# Dados da página pública (vão embutidos como JSON). Sem preço e sem o número exato do estoque:
# "max" é o limite do campo de quantidade.
module B2bCatalogs
  class PublicPayload
    def initialize(catalog, order)
      @catalog = catalog
      @order = order
    end

    def as_json(*)
      { catalog: catalog_json, order: order_json, styles: styles_json }
    end

    private

    def catalog_json
      { title: @catalog.title, notes: @catalog.notes.to_s, closed: @catalog.closed?,
        needs_identification: @catalog.kind_general?,
        refreshed_at: @catalog.stock_refreshed_at&.strftime('%d/%m às %H:%M') }
    end

    def order_json
      return nil unless @order

      { customer_name: @order.customer_name, customer_registration: B2bCatalogs::Cnpj.format(@order.customer_registration),
        converted: @order.converted?, persisted: @order.persisted?,
        quantities: @order.persisted? ? @order.items.to_h { |i| [i.b2b_catalog_variant_id.to_s, i.quantity] } : {} }
    end

    def styles_json
      @catalog.styles.map do |style, colors|
        { name: style, colors: colors.map { |color| color_json(color) } }
      end
    end

    def color_json(color)
      { id: color.id, name: color.color_name, images: Array(color.image_urls).map { |url| sized(url) },
        variants: color.variants.map do |v|
          { id: v.id, size: v.size, availability: v.availability, max: v.sold_out? ? 0 : [v.available, 0].max }
        end }
    end

    # Shopify CDN redimensiona pela query string.
    def sized(url)
      return url unless url.to_s.include?('cdn.shopify.com')

      "#{url}#{url.include?('?') ? '&' : '?'}width=900"
    end
  end
end
