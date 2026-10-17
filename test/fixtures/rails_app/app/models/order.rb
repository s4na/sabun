class Order < ActiveRecord::Base
  validates :status, presence: true
end
