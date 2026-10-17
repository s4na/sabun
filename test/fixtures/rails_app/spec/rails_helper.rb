# frozen_string_literal: true
require_relative '../config/environment'
require 'rspec/rails'

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.use_transactional_fixtures = false
  config.before(:each) do
    Order.delete_all
    Rails.cache.clear
  end
end
