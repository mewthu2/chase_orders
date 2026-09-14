class Profile < ApplicationRecord
  has_many :user_profiles, dependent: :destroy
  has_many :users, through: :user_profiles
  has_many :screen_permissions, dependent: :destroy

  validates :name, presence: true

  ADMIN = 1
  MANAGER = 2
  USER = 3
  ADMIN_MARKETING = 5
  AGENT_MARKETING = 6

  def marketing_profile?
    [ADMIN_MARKETING, AGENT_MARKETING].include?(id)
  end

  def can_access?(screen_key)
    screen_permissions.exists?(screen_key: screen_key.to_s)
  end

  def screen_keys
    screen_permissions.pluck(:screen_key)
  end

  def screen_keys=(keys)
    clean = Array(keys).reject(&:blank?) & Screen.keys
    self.screen_permissions = clean.map { |k| screen_permissions.find_or_initialize_by(screen_key: k) }
  end
end
