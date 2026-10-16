module Whatsapp
  class Activity < ApplicationRecord
    belongs_to :conversation
    belongs_to :user
    belongs_to :assignee, class_name: 'User', optional: true
  end
end
