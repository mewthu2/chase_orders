class B2bCatalogOrderItem < ApplicationRecord
  belongs_to :catalog_order, class_name: 'B2bCatalogOrder', foreign_key: :b2b_catalog_order_id, inverse_of: :items
  belongs_to :variant, class_name: 'B2bCatalogVariant', foreign_key: :b2b_catalog_variant_id, inverse_of: :order_items

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
end
