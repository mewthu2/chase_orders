class B2bOrder < ApplicationRecord
  belongs_to :client, optional: true
  belongs_to :transfer_location, optional: true
  belongs_to :user
  has_many :b2b_order_items, dependent: :destroy
  accepts_nested_attributes_for :b2b_order_items, allow_destroy: true, reject_if: :all_blank

  enum :kind, { sale: 0, stock_transfer: 1 }
  enum :status, { draft: 0, saved: 1, transmitted: 2, error: 3 }
  enum :freight_paid_by, { shipper: 0, recipient: 1 }

  validates :client, presence: true, if: -> { sale? && !draft? }
  validates :transfer_location, presence: true, if: -> { stock_transfer? && !draft? }
  validate :must_have_items, unless: :draft?

  scope :recent, -> { order(created_at: :desc) }

  def transmittable?
    saved? || error?
  end

  private

  def must_have_items
    errors.add(:base, 'Pedido precisa ter pelo menos um item') if b2b_order_items.empty?
  end
end
