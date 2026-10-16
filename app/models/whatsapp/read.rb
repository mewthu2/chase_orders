module Whatsapp
  class Read < ApplicationRecord
    belongs_to :conversation
    belongs_to :user
  end
end
