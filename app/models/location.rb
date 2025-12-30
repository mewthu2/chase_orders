class Location < ApplicationRecord
  has_many :stock_corrections, dependent: :restrict_with_error
end
