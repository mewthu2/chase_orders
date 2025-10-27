class MarketingTask < ApplicationRecord
  # Associations
  belongs_to :marketing_campaign
  belongs_to :user, optional: true
  belongs_to :lead, optional: true

  # Validations
  validates :task_type, presence: true
  validates :status, presence: true
  validates :marketing_campaign_id, presence: true

  enum :status, {
    pending: 0,
    in_progress: 1,
    completed: 2,
    converted: 3,
    failed: 4
  }

  enum :task_type, {
    abandoned_cart: 0,
    product_recommendation: 1,
    win_back: 2,
    upsell: 3,
    cross_sell: 4
  }, prefix: true

  # Scopes
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  scope :for_campaign, ->(campaign_id) { where(marketing_campaign_id: campaign_id) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_status, ->(status) { where(status: status) }
  scope :converted_only, -> { where(status: :converted) }
  scope :overdue, -> { where(status: [:pending, :in_progress]).where('due_date < ?', Date.current) }
  scope :due_today, -> { where(status: [:pending, :in_progress]).where(due_date: Date.current) }
  scope :due_this_week, -> { where(status: [:pending, :in_progress]).where(due_date: Date.current.beginning_of_week..Date.current.end_of_week) }
  scope :unassigned, -> { where(user_id: nil) }
  scope :assigned, -> { where.not(user_id: nil) }

  # Callbacks
  before_validation :set_default_status, on: :create
  before_validation :set_due_date, on: :create

  # Serialization for lead_data JSON field

  # Instance Methods
  def can_be_started_by?(user)
    return false unless pending?
    return true if user.admin? || user.admin_marketing?
    return true if self.user_id == user.id
    false
  end

  def start_work!
    return false unless pending?
    update(status: :in_progress, started_at: Time.current)
  end

  def complete!
    return false unless in_progress?
    update(status: :completed, completed_at: Time.current)
  end

  def mark_as_converted!(order_number)
    return false unless in_progress? || completed?
    update(
      status: :converted,
      converted: true,
      order_number: order_number,
      completed_at: Time.current,
      converted_at: Time.current
    )
  end

  def mark_as_failed!(reason = nil)
    update(
      status: :failed,
      completed_at: Time.current,
      notes: [notes, "Falha: #{reason}"].compact.join("\n")
    )
  end

  def is_overdue?
    due_date.present? && due_date < Date.current && !completed? && !converted?
  end

  def days_until_due
    return nil if due_date.blank?
    (due_date - Date.current).to_i
  end

  def time_to_complete
    return nil if started_at.blank? || completed_at.blank?
    ((completed_at - started_at) / 1.hour).round(2)
  end

  def customer_name
    lead_data&.dig('customer', 'name') || lead_data&.dig('customer', 'email') || 'Cliente não identificado'
  end

  def customer_email
    lead_data&.dig('customer', 'email')
  end

  def customer_phone
    lead_data&.dig('customer', 'phone')
  end

  def cart_total
    lead_data&.dig('cart', 'total_price')
  end

  def cart_items_count
    lead_data&.dig('cart', 'line_items')&.count || 0
  end

  def abandoned_at
    lead_data&.dig('abandoned_checkout_url') ? lead_data['created_at'] : nil
  end

  private

  def set_default_status
    self.status ||= :pending
  end

  def set_due_date
    self.due_date ||= 7.days.from_now.to_date
  end
end
