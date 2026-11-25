# Nota fiscal de entrada (compra de fornecedor) lida do XML da NF-e, com os itens. Base da Colocação de estoque:
# a soma do que vai ao Log02 e ao Log03 tem que bater SKU a SKU com estes itens.
class StockEntry < ApplicationRecord
  STATUSES = {
    'aguardando' => ['Aguardando colocação', 'yellow', 'Ainda não subiram os CSVs do Log02 e do Log03.'],
    'em_colocacao' => ['Em colocação', 'blue', 'Já tem CSV ou nota de remessa, mas falta lado ou nota autorizada.'],
    'colocada' => ['Colocada', 'green', 'As notas de remessa do Log02 e do Log03 estão autorizadas.']
  }.freeze

  belongs_to :company, optional: true
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :items, -> { order(:position) }, class_name: 'StockEntryItem', dependent: :delete_all
  has_many :placements, class_name: 'StockPlacement', dependent: :destroy
  has_one_attached :xml

  validates :access_key, presence: true, uniqueness: true, format: { with: /\A\d{44}\z/ }
  validates :number, presence: true

  scope :recent, -> { order(issued_at: :desc, id: :desc) }

  def placement(side) = placements.detect { |p| p.side == side }

  # Quantidade da nota por SKU (o mesmo SKU pode vir em mais de uma linha).
  def quantities
    items.each_with_object(Hash.new(0)) { |i, acc| acc[i.sku] += i.quantity.to_i }
  end

  # Valor unitário por SKU para a remessa: o da nota (média ponderada se o SKU vier repetido).
  def unit_prices
    items.group_by(&:sku).transform_values do |list|
      qty = list.sum { |i| i.quantity.to_d }
      qty.positive? ? (list.sum { |i| i.quantity.to_d * i.unit_price.to_d } / qty).round(6) : list.first.unit_price.to_d
    end
  end

  def pieces = items.sum { |i| i.quantity.to_i }

  def status
    sides = StockPlacement::SIDES.keys
    return 'colocada' if sides.all? { |s| placement(s)&.authorized_note }
    return 'em_colocacao' if placements.any?

    'aguardando'
  end

  # Conferência SKU a SKU: [{ sku:, description:, entry:, log02:, log03:, diff: }], com os SKUs que estão só no CSV.
  def reconciliation
    entry = quantities
    by_side = StockPlacement::SIDES.keys.index_with { |s| placement(s)&.quantities || {} }
    descriptions = items.to_h { |i| [i.sku, i.description] }
    skus = (entry.keys + by_side.values.flat_map(&:keys)).uniq
    skus.map do |sku|
      log02 = by_side['log02'][sku].to_i
      log03 = by_side['log03'][sku].to_i
      { sku: sku, description: descriptions[sku], entry: entry[sku].to_i, log02: log02, log03: log03,
        diff: log02 + log03 - entry[sku].to_i, outside: !entry.key?(sku) }
    end
  end

  def both_sides? = StockPlacement::SIDES.keys.all? { |s| placement(s) }
  def balanced? = both_sides? && reconciliation.all? { |r| r[:diff].zero? && !r[:outside] }

  # Algum lado já tem nota de remessa que vale (gerada, assinada ou autorizada): a entrada não pode ser apagada.
  def locked? = placements.any?(&:active_note)
end
