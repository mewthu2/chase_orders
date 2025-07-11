class OrderPdvItem < ApplicationRecord
  belongs_to :order_pdv
  belongs_to :product

  validates :sku, :product_name, presence: true
  validates :price, :quantity, presence: true, numericality: { greater_than: 0 }
  validates :total, presence: true, numericality: { greater_than: 0 }, allow_blank: false

  before_validation :calculate_total

  def formatted_price
    "R$ #{sprintf('%.2f', price)}"
  end

  def formatted_total
    "R$ #{sprintf('%.2f', total)}"
  end

  private

  def calculate_total
    self.total = price * quantity
  end
end
