# frozen_string_literal: true
require 'rspec/core'
require_relative 'recorder'

RSpec.configure do |config|
  config.before(:suite) do
    snapshot = Sabun::Recorder.snapshot
    boot_methods = Sabun::Recorder.changed({}, snapshot, methods_only: true)
    Sabun::Recorder.instance_variable_set(:@previous, snapshot)
    Sabun::Recorder.instance_variable_set(:@common, boot_methods)
  end
  config.around(:each) do |example|
    current = Sabun::Recorder.snapshot
    previous = Sabun::Recorder.instance_variable_get(:@previous) || {}
    Sabun::Recorder.instance_variable_set(:@common, (Sabun::Recorder.instance_variable_get(:@common) || []) | Sabun::Recorder.changed(previous, current, methods_only: true))
    begin
      example.run
    ensure
      after = Sabun::Recorder.snapshot
      deps = Sabun::Recorder.changed(current, after)
      Sabun::Recorder.record_file(example.metadata[:file_path], dependencies: deps, complete: !example.exception)
      Sabun::Recorder.instance_variable_set(:@previous, after)
    end
  end
  config.after(:suite) do
    previous = Sabun::Recorder.instance_variable_get(:@previous) || {}
    trailing = Sabun::Recorder.changed(previous, Sabun::Recorder.snapshot)
    common = (Sabun::Recorder.instance_variable_get(:@common) || []) | trailing
    Sabun::Recorder.records.each_value { |entry| entry['dependencies'] |= common.filter_map { |dep| Sabun::Core.relative(dep) } }
    Sabun::Recorder.finish!
  end
end
