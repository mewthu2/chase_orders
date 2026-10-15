class CashbackUnificationSource < ApplicationRecord
  belongs_to :cashback_unification
  validates :shopify_node_id, presence: true, uniqueness: true
end
