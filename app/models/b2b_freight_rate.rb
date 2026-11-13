# Tabela de frete do atacado: o frete do pedido sai da faixa em que o valor do pedido (produtos com o desconto)
# cai. Acima da última faixa vale o preço da última.
class B2bFreightRate < ApplicationRecord
  validates :min_value, :max_value, :price, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :range_order
  validate :no_overlap

  scope :ordered, -> { order(:min_value) }

  def self.price_for(amount)
    rates = ordered.to_a
    return 0.to_d if rates.empty?

    # Faixas ordenadas e sem sobreposição: a última que começa até o valor é a dele (ou a de baixo, num buraco).
    (rates.select { |r| r.min_value <= amount.to_d }.last || rates.first).price.to_d
  end

  # Para o formulário do pedido calcular no navegador: [[mín, máx, preço], ...].
  def self.table
    ordered.map { |r| [r.min_value.to_f, r.max_value.to_f, r.price.to_f] }
  end

  private

  def range_order
    return if min_value.nil? || max_value.nil?

    errors.add(:max_value, 'precisa ser maior que o mínimo') if max_value <= min_value
  end

  def no_overlap
    return if min_value.nil? || max_value.nil?

    clash = self.class.where.not(id: id).where('min_value <= ? AND max_value >= ?', max_value, min_value).ordered.first
    return unless clash

    fmt = ->(v) { ActiveSupport::NumberHelper.number_to_currency(v, unit: 'R$ ', separator: ',', delimiter: '.') }
    errors.add(:base, "A faixa encosta na de #{fmt.(clash.min_value)} a #{fmt.(clash.max_value)}.")
  end
end
