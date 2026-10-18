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
    rescue Error, LoadError, StandardError
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

    def initialize(root: Core.root)
      @root = root
    end

    def plan(config:, baseline_path:, head: 'HEAD')
      map = Core.read_json(baseline_path)
      suites = config.fetch('suites')
      inventory = Core.inventory(config, root: @root)
      current_head = Core.sha(head, root: @root)
      changes = nil
      reasons = []
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
      decisions = suites.to_h do |suite|
        id = suite.fetch('id')
        units = inventory.fetch(id)
        test_paths = units.map { |unit| unit.split('::', 2).first }.uniq
        observed = map.fetch('units', {}).fetch(id, {})
        selected = []
        explanations = {}
        units.each do |unit|
          why = []
          why.concat(reasons)
          entry = observed[unit]
          why << 'unobserved_or_incomplete' unless entry.is_a?(Hash) && entry['complete'] == true && entry['dependencies'].is_a?(Array)
          why << 'test_changed' if changes.any? { |change| change['path'] == unit.split('::', 2).first }
          changes.each do |change|
            # A changed test file selects its own unit above; it must not fan
            # out as an application-level structural change to sibling units.
            next if test_paths.include?(change['path'])
            if change['scope'] == 'ruby_body'
              why << "ruby_dependency:#{change['path']}" if entry && entry.fetch('dependencies', []).include?(change['path'])
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
  end
end
