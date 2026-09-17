class AddressCorrection < ApplicationRecord
  validates :tiny_order_id, presence: true, uniqueness: true

  def self.for(tiny_order_id)
    find_by(tiny_order_id: tiny_order_id.to_s)
  end
end
