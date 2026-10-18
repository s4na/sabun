# frozen_string_literal: true
require_relative 'core'

module Sabun
  class ChangeClassifier
    def initialize(root:, baseline:, head:)
      @root, @baseline, @head = root, baseline, head
    end

    def changes
      output = Core.git('diff', '--no-renames', '--name-status', '-z', @baseline, @head, root: @root)
      fields = output.split("\0")
      fields.each_slice(2).map do |status, path|
        raise Error, 'unexpected git diff output' unless status && path
        { 'path' => path, 'status' => status, 'scope' => classify(status, path) }
      end
    end

    private

    def classify(status, path)
      return 'structural' unless status == 'M' && path.end_with?('.rb')
      before = Core.git('show', "#{@baseline}:#{path}", root: @root)
      after = Core.git('show', "#{@head}:#{path}", root: @root)
      method_body_only?(before, after) ? 'ruby_body' : 'structural'
    rescue StandardError, LoadError
      'structural'
    end

    def method_body_only?(before, after)
      require 'prism'
      old = masked(before)
      newer = masked(after)
      old && newer && old[0] == newer[0] && old[1] == newer[1] && old[2] != newer[2]
    end

    def masked(source)
      result = Prism.parse(source)
      return nil unless result.success?
      bodies = []
      traverse = lambda do |node|
        if node.is_a?(Prism::DefNode)
          return nil unless node.body && node.body.location
          body = node.body.location
          bodies << [body.start_offset, body.end_offset, source.byteslice(body.start_offset...body.end_offset)]
        else
          node.compact_child_nodes.each { |child| traverse.call(child) }
        end
      end
      traverse.call(result.value)
      return nil if bodies.empty?
      return nil if bodies.each_cons(2).any? { |a, b| a[1] > b[0] }
      return nil if bodies.any? { |_, _, body| body.match?(/\b(?:class|module|def|alias|undef|eval|class_eval|module_eval|define_method|define_singleton_method|const_set|remove_method|before_action|after_action|prepend_before_action)\b/) }
      offset = 0
      parts = []
      bodies.each do |start, finish, _|
        parts << source.byteslice(offset...start)
        parts << '__SABUN_METHOD_BODY__'
        offset = finish
      end
      parts << source.byteslice(offset..)
      [parts.join, bodies.size, bodies.map(&:last)]
    end
  end

  class Selector
    SCHEMA = 1
    SUITE_WIDE_DYNAMIC_CALLS = %i[
      shared_context shared_examples class_eval module_eval define_method define_singleton_method
      const_set remove_method alias_method
    ].freeze
    SUITE_WIDE_ASSIGNMENT_TYPES = %i[
      global_variable_write_node global_variable_and_write_node global_variable_or_write_node
      global_variable_operator_write_node class_variable_write_node class_variable_and_write_node
      class_variable_or_write_node class_variable_operator_write_node constant_write_node
      constant_and_write_node constant_or_write_node constant_operator_write_node constant_path_write_node
      constant_path_and_write_node constant_path_or_write_node constant_path_operator_write_node
    ].freeze

    def initialize(root: Core.root)
      @root = root
    end

    def plan(config:, baseline_path:, head: 'HEAD')
      map = Core.read_json(baseline_path)
      map = {} unless map.is_a?(Hash)
      suites = config.fetch('suites')
      inventory = Core.inventory(config, root: @root)
      current_head = Core.sha(head, root: @root)
      changes = nil
      reasons = []
      baseline_units = map.fetch('units', {})
      baseline_units = {} unless baseline_units.is_a?(Hash)
      if map['schema_version'] != SCHEMA || !map['complete']
        reasons << 'invalid_or_incomplete_baseline'
      elsif map['fingerprint'] != Core.fingerprint(root: @root, config: config)
        reasons << 'environment_mismatch'
      elsif map['suite_ids'] != suites.map { |s| s['id'] }
        reasons << 'suite_inventory_changed'
      elsif map['commit'].to_s !~ /\A[0-9a-f]{40}\z/
        reasons << 'invalid_baseline_commit'
      else
        begin
          changes = ChangeClassifier.new(root: @root, baseline: map.fetch('commit'), head: current_head).changes
        rescue Error
          reasons << 'diff_unavailable'
        end
      end
      changes ||= []
      test_paths = inventory.values.flatten.map { |unit| unit.split('::', 2).first }.uniq
      decisions = suites.to_h do |suite|
        id = suite.fetch('id')
        units = inventory.fetch(id)
        suite_test_paths = units.map { |unit| unit.split('::', 2).first }.uniq
        observed = baseline_units.fetch(id, {})
        observed = {} unless observed.is_a?(Hash)
        selected = []
        explanations = {}
        units.each do |unit|
          why = []
          why.concat(reasons)
          entry = observed[unit]
          valid_entry = valid_observation?(entry)
          why << 'unobserved_or_incomplete' unless valid_entry
          why << 'test_changed' if changes.any? { |change| change['path'] == unit.split('::', 2).first }
          changes.each do |change|
            if test_paths.include?(change['path'])
              # A configured test may also be required as executable support
              # code by another unit; preserve that recorded dependency.
              if suite_test_paths.include?(change['path']) &&
                  suite_wide_test_behavior?(change, baseline: map.fetch('commit'), head: current_head)
                why << "suite_wide_test_behavior:#{change['path']}"
              elsif valid_entry && entry['dependencies'].include?(change['path'])
                why << "test_dependency:#{change['path']}"
              end
              next
            end
            if change['scope'] == 'ruby_body'
              why << "ruby_dependency:#{change['path']}" if valid_entry && entry['dependencies'].include?(change['path'])
            else
              why << "unclassified_or_structural:#{change['path']}"
            end
          end
          selected << unit unless why.empty?
          explanations[unit] = why.uniq
        end
        [id, { 'kind' => suite.fetch('kind'), 'selected' => selected, 'skipped' => units - selected, 'reasons' => explanations }]
      end
      { 'schema_version' => SCHEMA, 'head' => current_head, 'baseline' => map['commit'], 'fingerprint' => Core.fingerprint(root: @root, config: config), 'changes' => changes, 'suites' => decisions }
    end

    private

    def suite_wide_test_behavior?(change, baseline:, head:)
      return false unless change['path'].end_with?('.rb')

      before = Core.git('show', "#{baseline}:#{change['path']}", root: @root)
      after = Core.git('show', "#{head}:#{change['path']}", root: @root)
      require 'prism'
      [before, after].any? { |source| suite_wide_source?(source) }
    rescue StandardError, LoadError
      true
    end

    def suite_wide_source?(source)
      result = Prism.parse(source)
      return true unless result.success?

      found = false
      traverse = lambda do |node|
        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          found = true
        elsif node.is_a?(Prism::CallNode)
          receiver = node.receiver
          receiver_name = receiver.full_name if receiver.respond_to?(:full_name)
          found ||= (node.name == :configure && receiver_name == 'RSpec')
          found ||= SUITE_WIDE_DYNAMIC_CALLS.include?(node.name)
          found ||= SUITE_WIDE_ASSIGNMENT_TYPES.include?(node.type)
          found ||= receiver_name == 'ENV' && %i[[]= store delete clear update replace].include?(node.name)
          found ||= %i[include prepend extend].include?(node.name) &&
            (receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode))
        end
        node.compact_child_nodes.each { |child| traverse.call(child) } unless found
      end
      traverse.call(result.value)
      found
    end

    def valid_observation?(entry)
      entry.is_a?(Hash) && entry['complete'] == true && entry['dependencies'].is_a?(Array) &&
        entry['dependencies'].all? { |dependency| dependency.is_a?(String) && Core.relative(dependency, @root) == dependency }
    rescue ArgumentError, TypeError
      false
    end
  end
end
