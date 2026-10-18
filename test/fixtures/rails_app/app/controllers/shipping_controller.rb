class ShippingController < ActionController::Base
  def show
    render plain: Shipping.label
  end
end
