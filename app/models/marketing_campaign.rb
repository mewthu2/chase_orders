class MarketingCampaign < ApplicationRecord
  # Associations
  has_many :campaign_users, dependent: :destroy
  has_many :users, through: :campaign_users
  has_many :marketing_tasks, dependent: :destroy

  # Validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :objective, presence: true
  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :users_per_week, presence: true, numericality: { greater_than: 0 }
  validates :campaign_type, presence: true
  validate :end_date_after_start_date

  # Enums
  enum status: {
    draft: 0,
    active: 1,
    paused: 2,
    completed: 3,
    cancelled: 4
  }, _prefix: true

  enum campaign_type: {
    abandoned_cart: 0,
    product_recommendation: 1,
    win_back: 2,
    upsell: 3,
    cross_sell: 4
  }, _prefix: true

  # Scopes
  scope :active_campaigns, -> { where(status: :active).where('start_date <= ? AND end_date >= ?', Date.current, Date.current) }
  scope :upcoming, -> { where('start_date > ?', Date.current) }
  scope :past, -> { where('end_date < ?', Date.current) }
  scope :by_type, ->(type) { where(campaign_type: type) }
  scope :recent, -> { order(created_at: :desc) }

  # Callbacks
  before_validation :set_default_status, on: :create
  after_create :activate_if_started

  # Instance Methods
  def active?
    status_active? && Date.current.between?(start_date, end_date)
  end

  def duration_days
    (end_date - start_date).to_i + 1
  end

  def total_tasks
    marketing_tasks.count
  end

  def pending_tasks
    marketing_tasks.pending.count
  end

  def in_progress_tasks
    marketing_tasks.in_progress.count
  end

  def completed_tasks
    marketing_tasks.completed.count
  end

  def converted_tasks
    marketing_tasks.converted.count
  end

  def conversion_rate
    return 0 if completed_tasks.zero?
    (converted_tasks.to_f / completed_tasks * 100).round(2)
  end

  def completion_rate
    return 0 if total_tasks.zero?
    (completed_tasks.to_f / total_tasks * 100).round(2)
  end

  def average_tasks_per_user
    return 0 if users.count.zero?
    (total_tasks.to_f / users.count).round(2)
  end

  def top_performers(limit = 5)
    users.joins(:marketing_tasks)
         .where(marketing_tasks: { marketing_campaign_id: id, status: [:completed, :converted] })
         .group('users.id')
         .select('users.*, COUNT(marketing_tasks.id) as tasks_count')
         .order('tasks_count DESC')
         .limit(limit)
  end

  def can_be_edited?
    status_draft? || status_paused?
  end

  def can_be_activated?
    status_draft? || status_paused?
  end

  def can_be_paused?
    status_active?
  end

  def activate!
    update(status: :active) if can_be_activated?
  end

  def pause!
    update(status: :paused) if can_be_paused?
  end

  def complete!
    update(status: :completed)
  end

  private

  def end_date_after_start_date
    return if end_date.blank? || start_date.blank?

    errors.add(:end_date, 'deve ser posterior à data de início') if end_date < start_date
  end

  def set_default_status
    self.status ||= :draft
  end

  def activate_if_started
    activate! if start_date <= Date.current && end_date >= Date.current
  end
end
