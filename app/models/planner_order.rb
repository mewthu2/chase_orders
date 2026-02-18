class PlannerOrder < ApplicationRecord
  belongs_to :user, optional: true
  has_many :planner_order_items, dependent: :destroy
  
  validates :reference, presence: true, uniqueness: true
  
  enum status: {
    draft: 0,
    saved: 1,
    transmitted: 2,
    error: 3
  }
  
  def total_items
    planner_order_items.sum(:quantity)
  end
end
