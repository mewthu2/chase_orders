module Whatsapp
  class Membership < ApplicationRecord
    belongs_to :connection
    belongs_to :user
    validates :user_id, uniqueness: { scope: :connection_id }
  end
end
