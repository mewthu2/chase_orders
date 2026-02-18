class PlannerOrderItem < ApplicationRecord
  belongs_to :planner_order
  
  validates :name, :sku, :quantity, presence: true
  validates :quantity, numericality: { greater_than: 0 }
end
