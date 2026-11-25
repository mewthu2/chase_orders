# Percentual de comissão de uma pessoa (usuário que digita o pedido ou consultor) num mês. Sem linha no mês, a
# pessoa fica sem percentual (comissão zero). Cada mês é independente: mudar um não mexe nos outros.
class CommissionRate < ApplicationRecord
  belongs_to :beneficiary, polymorphic: true

  validates :month, presence: true
  validates :percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :beneficiary_type, inclusion: { in: %w[User Consultant] }

  before_validation { self.month = month&.beginning_of_month }

  # { ['User', 1] => 2.5, ['Consultant', 3] => 5 }
  def self.for_month(month)
    where(month: month.beginning_of_month).pluck(:beneficiary_type, :beneficiary_id, :percent)
                                           .to_h { |type, id, percent| [[type, id], percent] }
  end

  # Copia os percentuais do último mês anterior que tenha algum, só para quem ainda não tem no mês.
  def self.copy_previous!(month)
    month = month.beginning_of_month
    source = where(month: ...month).maximum(:month)
    return 0 unless source

    existing = for_month(month)
    where(month: source).reject { |r| existing.key?([r.beneficiary_type, r.beneficiary_id]) }.count do |r|
      create!(month: month, beneficiary_type: r.beneficiary_type, beneficiary_id: r.beneficiary_id, percent: r.percent)
    end
  end
end
