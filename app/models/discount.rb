class Discount < ApplicationRecord
  validates :shopify_node_id, presence: true, uniqueness: true
  validates :code, presence: true
  validates :title, presence: true

  scope :active, -> { where(is_active: true) }
  scope :inactive, -> { where(is_active: false) }
  scope :expired, -> { where(is_expired: true) }
  scope :by_code, ->(code) { where('LOWER(code) = ?', code.downcase) }

  def self.find_by_code(code)
    by_code(code).first
  end

  def expired?
    return false unless ends_at.present?
    ends_at <= Time.current
  end

  def started?
    return true unless starts_at.present?
    starts_at <= Time.current
  end

  def currently_active?
    started? && !expired? && is_active
  end

  def update_status_from_dates!
    now = Time.current
    
    new_is_active = true
    new_is_expired = false

    if starts_at && starts_at > now
      new_is_active = false
    elsif ends_at && ends_at <= now
      new_is_active = false
      new_is_expired = true
    end

    update!(
      is_active: new_is_active,
      is_expired: new_is_expired
    )
  end
end
