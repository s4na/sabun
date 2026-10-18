class Order < ActiveRecord::Base
  def paid?
    status == 'paid'
  end

  validates :status, presence: true
end
