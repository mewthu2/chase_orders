module Whatsapp
  class ContactAlias < ApplicationRecord
    belongs_to :connection
    belongs_to :contact
  end
end
