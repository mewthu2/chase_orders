module Whatsapp
  class Receipt < ApplicationRecord
    belongs_to :connection
  end
end
