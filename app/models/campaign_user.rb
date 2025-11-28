class CampaignUser < ApplicationRecord
  # Associations
  belongs_to :marketing_campaign
  belongs_to :user

  # Validations
  validates :marketing_campaign_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :marketing_campaign_id, message: 'já está participando desta campanha' }

  # Scopes
  scope :active, -> { joins(:marketing_campaign).merge(MarketingCampaign.active_campaigns) }
  scope :for_campaign, ->(campaign_id) { where(marketing_campaign_id: campaign_id) }
  scope :for_user, ->(user_id) { where(user_id:) }

  # Instance Methods
  def tasks_count
    user.marketing_tasks.where(marketing_campaign_id:).count
  end

  def pending_tasks_count
    user.marketing_tasks.where(marketing_campaign_id:, status: :pending).count
  end

  def completed_tasks_count
    user.marketing_tasks.where(marketing_campaign_id:, status: [:completed, :converted]).count
  end

  def converted_tasks_count
    user.marketing_tasks.where(marketing_campaign_id:, status: :converted).count
  end

  def conversion_rate
    return 0 if completed_tasks_count.zero?
    (converted_tasks_count.to_f / completed_tasks_count * 100).round(2)
  end

  def performance_score
    completion_score = completed_tasks_count * 10
    conversion_score = conversion_rate
    (completion_score + conversion_score).round(2)
  end
end
