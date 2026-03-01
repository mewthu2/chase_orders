class Customer < ApplicationRecord
  has_many :orders, dependent: :nullify

  validates :shopify_customer_id, uniqueness: true

  def full_name
    [first_name, last_name].compact.join(' ')
  end
end