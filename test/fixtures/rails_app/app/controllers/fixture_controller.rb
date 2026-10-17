class FixtureController < ActionController::Base
  def reset
    Order.delete_all
    Rails.cache.clear
    head :no_content
  end
end
