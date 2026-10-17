# frozen_string_literal: true
require 'rails'
require 'action_controller/railtie'
require 'active_record/railtie'
require 'active_job/railtie'

module SabunFixture
  class Application < Rails::Application
    config.load_defaults 7.2
    config.root = File.expand_path('..', __dir__)
    config.eager_load = false
    config.enable_reloading = false
    config.secret_key_base = 'test-only-not-used-outside-this-fixture'
    config.hosts.clear
    config.action_controller.allow_forgery_protection = false
    config.action_dispatch.show_exceptions = :none
    config.active_job.queue_adapter = :inline
    config.active_record.dump_schema_after_migration = false
    config.public_file_server.enabled = true
    config.logger = Logger.new(File::NULL)
    config.cache_store = :memory_store
  end
end
