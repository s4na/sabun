class OrdersController < ActionController::Base
  def create
    order = Order.create!(status: 'pending')
    ReceiptJob.perform_later(order.id)
    redirect_to "/orders/#{order.id}"
  end

  def show
    @order = Order.find(params[:id])
  end
end
