class FixtureController < ActionController::Base
  def reset
    Order.delete_all
    Rails.cache.clear
    head :no_content
  end

  def cleanup
    Cleanup.run
    head :no_content
  end
end
