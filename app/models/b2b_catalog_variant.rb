# Um tamanho de uma cor do catálogo. available é o disponível do Correios B2B − reservas da fila,
# gravado de hora em hora; a página pública só mostra o nível (availability).
class B2bCatalogVariant < ApplicationRecord
  LOW_STOCK = 5

  belongs_to :catalog_product, class_name: 'B2bCatalogProduct', foreign_key: :b2b_catalog_product_id, inverse_of: :variants
  has_many :order_items, class_name: 'B2bCatalogOrderItem', foreign_key: :b2b_catalog_variant_id,
           dependent: :destroy, inverse_of: :variant

  enum :availability, { available: 0, low: 1, sold_out: 2 }

  def self.availability_for(quantity)
    return :sold_out if quantity.to_i <= 0

    quantity.to_i <= LOW_STOCK ? :low : :available
  end
end
