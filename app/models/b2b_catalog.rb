# Catálogo B2B: cores (B2bCatalogProduct) com seus tamanhos (B2bCatalogVariant), publicado num link
# público onde o lojista monta uma encomenda (B2bCatalogOrder). Sem preço.
class B2bCatalog < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :user
  has_many :products, -> { order(:position, :id) }, class_name: 'B2bCatalogProduct',
           dependent: :destroy, inverse_of: :catalog
  has_many :variants, through: :products
  has_many :catalog_orders, class_name: 'B2bCatalogOrder', dependent: :destroy, inverse_of: :catalog

  accepts_nested_attributes_for :products, allow_destroy: true

  enum :kind, { general: 0, client: 1 }, prefix: true
  enum :status, { active: 0, closed: 1 }

  KIND_LABELS = { 'general' => 'Geral', 'client' => 'Por cliente' }.freeze

  before_validation { self.client = nil if kind_general? }
  before_validation(on: :create) { self.public_token ||= self.class.new_token }

  validates :title, presence: true
  validates :client, presence: true, if: :kind_client?
  validates :public_token, presence: true, uniqueness: true

  def self.new_token = SecureRandom.urlsafe_base64(24)

  def regenerate_public_token!
    update!(public_token: self.class.new_token)
  end

  # [[modelo, [cores...]], ...] na ordem em que o modelo aparece pela primeira vez.
  def styles
    products.to_a.group_by(&:style_name).to_a
  end

  # Mensagem de erro se alguma quantidade não puder ser aceita; nil se está tudo certo.
  def quantity_error(quantities)
    by_id = variants.includes(:catalog_product).index_by(&:id)

    quantities.each do |variant_id, quantity|
      variant = by_id[variant_id.to_i]
      return 'Produto fora deste catálogo.' unless variant
      next unless quantity.to_i > [variant.available, 0].max

      product = variant.catalog_product
      return "#{product.style_name} #{product.color_name} #{variant.size}: quantidade acima do disponível.".squish
    end

    nil
  end
end
