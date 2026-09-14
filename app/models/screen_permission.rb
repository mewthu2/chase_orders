class ScreenPermission < ApplicationRecord
  belongs_to :profile

  validates :screen_key, presence: true
end
