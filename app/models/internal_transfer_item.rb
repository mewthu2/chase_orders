class InternalTransferItem < ApplicationRecord
  belongs_to :internal_transfer_shipment, inverse_of: :items
  belongs_to :product

  enum :status, { pending: 0, reserved: 1, received: 2, failed: 3, cancelled: 4 }

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validate :product_must_be_linked_to_shopify
  validate :not_duplicated_in_memory

  # Já passou por uma etapa no Shopify (reservado/recebido/cancelado): não muda mais.
  def locked?
    !pending? && !failed?
  end

  private

  def product_must_be_linked_to_shopify
    return if product.blank? || product.shopify_inventory_item_id.present?

    errors.add(:base, "Produto #{product.sku} não tem ID de inventário do Shopify")
  end

  def not_duplicated_in_memory
    shipment = internal_transfer_shipment
    return if shipment.blank? || product_id.blank?

    same = shipment.items.reject(&:marked_for_destruction?).select { |item| item.product_id == product_id }
    errors.add(:product_id, 'já está na lista para esta origem') if same.size > 1 && same.first != self
  end
end
