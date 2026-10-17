# frozen_string_literal: true
require_relative 'core'
require 'coverage'
require 'thread'

module Sabun
  module Recorder
    module_function

    def start!
      return if @started
      Coverage.start(lines: true, methods: true)
      @started = true
    end

    def capture_worker_identity!
      Core.assert_clean!
      config = Core.load_config(ENV.fetch('SABUN_CONFIG_PATH', 'sabun.json'))
      @worker_identity = { 'commit' => Core.sha, 'fingerprint' => Core.fingerprint(config: config) }
    rescue Error
      @worker_identity = nil
    end

    def worker_identity
      @worker_identity
    end

    def snapshot
      Coverage.peek_result.transform_values do |v|
        { lines: v.fetch(:lines, []).map { |count| count || 0 }, methods: v.fetch(:methods, {}) }
      end
    end

    def changed(before, after, methods_only: false)
      after.filter_map do |path, counts|
        previous = before[path] || { lines: [], methods: {} }
        methods = counts[:methods].any? { |key, value| value > (previous[:methods][key] || 0) }
        lines = counts[:lines].each_with_index.any? { |value, index| value > (previous[:lines][index] || 0) }
        path if methods || (!methods_only && lines)
      end
    end

    def record_file(path, dependencies:, complete:)
      @records ||= {}
      key = Core.relative(path)
      return unless key
      entry = (@records[key] ||= { 'complete' => true, 'dependencies' => [] })
      entry['complete'] &&= complete
      entry['dependencies'] |= dependencies.filter_map { |dep| Core.relative(dep) }
    end

    def records
      @records || {}
    end

    def flush!
      output = ENV['SABUN_RECORD_FILE']
      return unless output
      Core.write_json(output, { 'complete' => @finished == true, 'units' => records })
    end

    def finish!
      @finished = true
      flush!
    end
  end
end
