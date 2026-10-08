# Encomenda do lojista num catálogo. Pode ser alterada (pelo lojista ou pelo Honey) até virar pedido.
class B2bCatalogOrder < ApplicationRecord
  belongs_to :catalog, class_name: 'B2bCatalog', foreign_key: :b2b_catalog_id, inverse_of: :catalog_orders
  belongs_to :client, optional: true
  belongs_to :b2b_order, optional: true
  has_many :items, class_name: 'B2bCatalogOrderItem', foreign_key: :b2b_catalog_order_id,
           dependent: :destroy, inverse_of: :catalog_order

  enum :status, { pending: 0, seen: 1, converted: 2 }

  STATUS_LABELS = { 'pending' => 'Nova', 'seen' => 'Vista', 'converted' => 'Convertida em pedido' }.freeze

  before_validation { self.customer_registration = B2bCatalogs::Cnpj.digits(customer_registration).presence }
  before_validation(on: :create) { self.edit_token ||= SecureRandom.urlsafe_base64(24) }

  validates :customer_name, presence: true
  validates :customer_registration, uniqueness: { scope: :b2b_catalog_id }, allow_nil: true
  validate :registration_must_be_a_valid_cnpj, if: -> { catalog&.kind_general? }

  def total_pieces = items.sum(&:quantity)

  def editable? = !converted? && catalog.active?

  def replace_items!(quantities, edited_by:)
    valid_ids = catalog.variants.pluck(:id)

    transaction do
      items.delete_all
      quantities.each do |variant_id, quantity|
        next unless quantity.to_i.positive? && valid_ids.include?(variant_id.to_i)

        items.create!(b2b_catalog_variant_id: variant_id.to_i, quantity: quantity.to_i)
      end
      update!(last_edited_by: edited_by)
    end
    items.reset
  end

  def convert!(order)
    update!(status: :converted, b2b_order: order)
  end

  def matching_client
    return client if client
    return nil if customer_registration.blank?

    Client.where("REPLACE(REPLACE(REPLACE(registration, '.', ''), '/', ''), '-', '') = ?", customer_registration).first
  end

  private

  def registration_must_be_a_valid_cnpj
    errors.add(:base, 'CNPJ inválido.') unless B2bCatalogs::Cnpj.valid?(customer_registration)
  end
end
