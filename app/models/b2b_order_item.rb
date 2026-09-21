class B2bOrderItem < ApplicationRecord
  belongs_to :b2b_order

  validates :sku, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than_or_equal_to: 0 }
  validates :discount, numericality: { greater_than_or_equal_to: 0 }

  def product
    Product.find_by(sku: sku)
  end

  def line_total
    [price.to_f - discount.to_f, 0].max * quantity.to_i
  end
end
