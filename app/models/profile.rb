class Profile < ApplicationRecord
  has_many :user_profiles, dependent: :destroy
  has_many :users, through: :user_profiles

  validates :name, presence: true

  ADMIN = 1
  MANAGER = 2
  USER = 3
  ADMIN_MARKETING = 5
  AGENT_MARKETING = 6

  def marketing_profile?
    [ADMIN_MARKETING, AGENT_MARKETING].include?(id)
  end
end
