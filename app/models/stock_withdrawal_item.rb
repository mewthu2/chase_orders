class StockWithdrawalItem < ApplicationRecord
  belongs_to :stock_withdrawal, inverse_of: :items
  belongs_to :product
  belongs_to :location

  enum :status, { pending: 0, done: 1, failed: 2 }

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validate :product_must_be_linked_to_shopify
  validate :not_duplicated_in_memory

  # Linha já retirada do Shopify: não pode mais ser alterada nem refeita.
  def locked?
    done?
  end

  private

  # Sem o ID do item de inventário não dá para retirar no Shopify; avisamos antes de concluir.
  def product_must_be_linked_to_shopify
    return if product.blank? || product.shopify_inventory_item_id.present?

    errors.add(:base, "Produto #{product.sku} não tem ID de inventário do Shopify")
  end

  # Documento ainda não salvo: a unicidade do banco não enxerga linhas repetidas em memória.
  def not_duplicated_in_memory
    return if stock_withdrawal.blank? || product_id.blank? || location_id.blank?

    same = stock_withdrawal.items.reject(&:marked_for_destruction?).select { |i| i.product_id == product_id && i.location_id == location_id }
    errors.add(:product_id, 'já está na lista para esta location') if same.size > 1 && same.first != self
  end
end
