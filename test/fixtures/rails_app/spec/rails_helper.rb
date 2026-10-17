# frozen_string_literal: true
require_relative '../config/environment'
require 'rspec/rails'

# Rails/RSpecのバージョン差に依存せず、fixtureのジョブを同期実行する。
ActiveJob::Base.queue_adapter = :inline

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.use_transactional_fixtures = false
  config.before(:each) do
    ActiveJob::Base.queue_adapter = :inline
    Order.delete_all
    Rails.cache.clear
  end
end
