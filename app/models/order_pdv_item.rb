class OrderPdvItem < ApplicationRecord
  belongs_to :order_pdv
  belongs_to :product

  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :price, presence: true, numericality: { greater_than: 0 }

  before_save :calculate_total

  def formatted_price
    "R$ #{sprintf('%.2f', price)}"
  end

  def formatted_total
    "R$ #{sprintf('%.2f', total)}"
  end

  def total_price
    total
  end

  def total_price=(value)
    self.total = value
  end

  def sku
    product&.sku || 'N/A'
  end

  def product_name
    product&.shopify_product_name || 'Produto não encontrado'
  end

  def option1
    product&.option1
  end

  def option2
    product&.option2
  end

  def option3
    product&.option3
  end

  private

  def calculate_total
    self.total = (price || 0) * (quantity || 0)
  end
end
