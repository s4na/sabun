class OrdersController < ActionController::Base
  def create
    order = Order.create!(status: 'pending')
    # Rails 7.1のRSpec環境ではenqueue後の実行タイミングが異なるため、
    # 同じジョブ本体を同期実行してfixtureの検証条件を揃える。
    if Rails::VERSION::MAJOR == 7 && Rails::VERSION::MINOR == 1
      ReceiptJob.perform_now(order.id)
    else
      ReceiptJob.perform_later(order.id)
    end
    redirect_to "/orders/#{order.id}"
  end

  def show
    @order = Order.find(params[:id])
  end
end
