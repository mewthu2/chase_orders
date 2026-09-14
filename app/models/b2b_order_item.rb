class B2bOrderItem < ApplicationRecord
  belongs_to :b2b_order

  validates :sku, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than_or_equal_to: 0 }

  def product
    Product.find_by(sku: sku)
  end
end
