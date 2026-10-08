# Uma cor do catálogo (= um produto do Shopify). As variantes (tamanhos) nascem dos SKUs escolhidos.
class B2bCatalogProduct < ApplicationRecord
  SIZE_ORDER = %w[PP XP P M G GG XG XGG EG EGG U UN].freeze

  belongs_to :catalog, class_name: 'B2bCatalog', foreign_key: :b2b_catalog_id, inverse_of: :products
  has_many :variants, -> { order(:position, :id) }, class_name: 'B2bCatalogVariant',
           foreign_key: :b2b_catalog_product_id, dependent: :destroy, inverse_of: :catalog_product

  attribute :skus

  validates :style_name, presence: true

  after_create :create_variants_from_skus

  def main_image = Array(image_urls).first

  private

  def create_variants_from_skus
    found = Product.where(sku: Array(skus).map { |s| s.to_s.strip }.reject(&:blank?)).to_a
    sorted = found.sort_by { |p| [SIZE_ORDER.index(p.option1.to_s.strip.upcase) || SIZE_ORDER.size, p.option1.to_s] }

    sorted.each_with_index do |product, index|
      variants.create!(sku: product.sku.to_s.upcase, size: product.option1.presence || product.sku, position: index)
    end

    update_columns(shopify_product_id: shopify_product_id.presence || found.filter_map(&:shopify_product_id).first,
                   image_urls: Array(image_urls).presence || found.filter_map(&:image_url).uniq.first(1))
  end
end
