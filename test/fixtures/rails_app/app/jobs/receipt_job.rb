class ReceiptJob < ActiveJob::Base
  def perform(order_id)
    Order.find(order_id).update!(status: 'paid')
  end
end
