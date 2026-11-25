# Percentual de comissão de uma pessoa: o vendedor (usuário que digita o pedido) ou o consultor (quem recomendou).
# É geral, vale para todos os meses. Sem linha, a pessoa fica sem percentual (comissão zero).
class CommissionRate < ApplicationRecord
  self.ignored_columns += ['month'] # do tempo em que era mês a mês

  belongs_to :beneficiary, polymorphic: true

  validates :percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :beneficiary_type, inclusion: { in: %w[User Consultant] }
  validates :beneficiary_id, uniqueness: { scope: :beneficiary_type }

  # { ['User', 1] => 2.5, ['Consultant', 3] => 5 }
  def self.percents
    pluck(:beneficiary_type, :beneficiary_id, :percent).to_h { |type, id, percent| [[type, id], percent] }
  end
end
