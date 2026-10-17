# frozen_string_literal: true
require_relative '../config/environment'
require 'rspec/rails'

# Rails/RSpecのバージョン差に依存せず、fixtureのジョブを同期実行する。
ActiveJob::Base.queue_adapter = :inline

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.use_transactional_fixtures = false
  config.before(:each) do |example|
    ActiveJob::Base.queue_adapter = :inline
    # unrelated specをOrderモデルの依存にしない。実際にDBを使うspecだけ初期化する。
    Order.delete_all if example.metadata[:type] == :model || example.metadata[:file_path].end_with?('/requests/order_spec.rb')
    Rails.cache.clear
  end
end
