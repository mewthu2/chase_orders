# Consultor que vende para os lojistas do atacado. Recebe comissão quando o pedido é pago (Financeiro).
class Consultant < ApplicationRecord
  has_many :b2b_orders, dependent: :nullify
  has_many :commission_rates, as: :beneficiary, dependent: :destroy

  validates :name, presence: true, length: { maximum: 120 }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  before_validation { self.name = name.to_s.squish }
end
