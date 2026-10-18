class CheckoutsController < ActionController::Base
  def show
    @price = Price.amount
    @banner = Rails.configuration.x.boot_label
  end

  private

  def deny_requests
    head :forbidden
  end
end
