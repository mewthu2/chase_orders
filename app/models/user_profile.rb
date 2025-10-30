class UserProfile < ApplicationRecord
  belongs_to :user
  belongs_to :profile

  validates :user_id, uniqueness: { scope: :profile_id, message: 'já possui este perfil' }
  validates :profile_id, presence: true
end
