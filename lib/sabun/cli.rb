# frozen_string_literal: true
require 'optparse'
require 'tmpdir'
require_relative 'selector'

module Sabun
  class CLI
    def self.start(argv = ARGV)
      new.run(argv)
    rescue Error, OptionParser::ParseError => e
      warn "sabun: #{e.message}"
      2
    end

    def run(argv)
      action = argv.shift
      case action
      when 'doctor' then doctor(argv)
      when 'record' then record(argv)
      when 'plan' then plan(argv)
      when 'explain' then explain(argv)
      when 'run' then execute(argv)
      when 'version', '--version' then puts Sabun::VERSION; 0
      else
        puts 'Usage: sabun doctor|record|plan|explain|run|version'
        2
      end
    end

    private

    def options(argv, specs)
      values = {}
      parser = OptionParser.new
      specs.each { |flag, key| parser.on("--#{flag} VALUE") { |value| values[key] = value } }
      parser.parse!(argv)
      values
    end

    def doctor(argv)
      args = options(argv, [['config', :config]])
      config = Core.load_config(args.fetch(:config, 'sabun.json'))
      puts JSON.pretty_generate({ ruby: RUBY_VERSION, git: Core.sha, suites: Core.inventory(config), fingerprint: Core.fingerprint })
      0
    end

    def record(argv)
      argv.delete('--all')
      args = options(argv, [['config', :config], ['out', :out]])
      raise Error, 'record requires --out' unless args[:out]
      config = Core.load_config(args.fetch(:config, 'sabun.json'))
      root = Core.root
      sha = Core.sha
      raise Error, 'record requires a clean tracked working tree' unless Core.git('status', '--porcelain', '--untracked-files=no').empty?
      inventory = Core.inventory(config)
      units = {}
      Dir.mktmpdir('sabun-record-') do |directory|
        config.fetch('suites').each do |suite|
          id = suite.fetch('id')
          output = File.join(directory, "#{id}.json")
          cmd = suite.fetch('command')
          if suite['kind'] == 'rspec'
            loader = File.expand_path('boot', __dir__)
            existing = ENV['RUBYOPT'].to_s
            rubyopt = "-r#{loader} #{existing}".strip
            Core.command!(cmd, env: { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output, 'RUBYOPT' => rubyopt })
          else
            Core.command!(cmd, env: { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output })
          end
          result = suite['kind'] == 'playwright' ? aggregate_e2e(output) : Core.read_json(output)
          raise Error, "incomplete recording for #{id}" unless result['complete'] == true
          observed = result.fetch('units')
          missing = inventory.fetch(id) - observed.keys
          raise Error, "unrecorded units in #{id}: #{missing.join(', ')}" unless missing.empty?
          units[id] = observed
        end
      end
      Core.write_json(args[:out], { 'schema_version' => 1, 'commit' => sha, 'fingerprint' => Core.fingerprint(root: root), 'suite_ids' => config.fetch('suites').map { |s| s['id'] }, 'complete' => true, 'units' => units })
      puts "baseline written to #{args[:out]}"
      0
    end

    def aggregate_e2e(output)
      manifest = Core.read_json("#{output}.manifest.json")
      entries = Dir.glob("#{output}.d/*.json")
      expected = manifest.fetch('tests')
      seen = Set.new
      units = {}
      entries.each do |path|
        data = Core.read_json(path)
        unit = data.fetch('unit')
        seen << data.fetch('test_id')
        entry = (units[unit] ||= { 'complete' => true, 'dependencies' => [] })
        entry['complete'] &&= data['complete'] == true
        entry['dependencies'] |= data.fetch('dependencies')
      end
      { 'complete' => manifest['complete'] == true && !expected.empty? && (expected - seen.to_a).empty?, 'units' => units }
    end

    def plan(argv)
      args = options(argv, [['config', :config], ['baseline', :baseline], ['head', :head], ['out', :out]])
      raise Error, 'plan requires --baseline and --out' unless args[:baseline] && args[:out]
      raise Error, 'plan requires a clean tracked working tree' unless Core.git('status', '--porcelain', '--untracked-files=no').empty?
      config = Core.load_config(args.fetch(:config, 'sabun.json'))
      head = args.fetch(:head, 'HEAD')
      raise Error, 'head must match checked-out HEAD' unless Core.sha(head) == Core.sha
      data = Selector.new.plan(config: config, baseline_path: args[:baseline], head: head)
      Core.write_json(args[:out], data)
      puts "plan written to #{args[:out]}"
      0
    end

    def explain(argv)
      args = options(argv, [['plan', :plan]])
      raise Error, 'explain requires --plan' unless args[:plan]
      data = Core.read_json(args[:plan])
      data.fetch('suites').each do |id, suite|
        puts "#{id}: #{suite.fetch('selected').size} selected, #{suite.fetch('skipped').size} skipped"
        suite.fetch('selected').each { |path| puts "  #{path}: #{suite.fetch('reasons').fetch(path).join(', ')}" }
      end
      0
    end

    def execute(argv)
      args = options(argv, [['config', :config], ['plan', :plan]])
      raise Error, 'run requires --plan' unless args[:plan]
      raise Error, 'run requires a clean tracked working tree' unless Core.git('status', '--porcelain', '--untracked-files=no').empty?
      config = Core.load_config(args.fetch(:config, 'sabun.json'))
      plan = Core.read_json(args[:plan])
      raise Error, 'stale or invalid plan' unless plan['schema_version'] == 1 && plan['head'] == Core.sha && plan['fingerprint'] == Core.fingerprint
      inventory = Core.inventory(config)
      raise Error, 'plan suites differ from config' unless plan.fetch('suites').keys == config.fetch('suites').map { |s| s['id'] }
      config.fetch('suites').each do |suite|
        id = suite.fetch('id')
        selection = plan.fetch('suites').fetch(id)
        selected = selection.fetch('selected')
        skipped = selection.fetch('skipped')
        raise Error, 'plan inventory mismatch' unless (selected + skipped).sort == inventory.fetch(id) && (selected & skipped).empty?
        next if selected.empty?
        command = suite.fetch('command')
        if suite['kind'] == 'rspec'
          Core.command!(command + selected)
        else
          selected.group_by { |unit| unit.split('::', 2).last }.each do |project, units|
            files = units.map { |unit| unit.split('::', 2).first }
            Core.command!(command + ['--project', project] + files)
          end
        end
      end
      0
    end
  end
end
