# frozen_string_literal: true
require 'minitest/autorun'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'open3'
require 'timeout'
require 'securerandom'
require 'digest'
require 'rbconfig'

# 実CLI・実テストランナーだけを呼ぶ。Selector/Recorderへのスタブや手作りマップは使わない。
class FixtureProject
  SOURCE = File.expand_path('../..', __dir__)
  Result = Struct.new(:status, :stdout, :stderr, :report, :label, keyword_init: true)
  attr_reader :root, :kind, :suite, :evidence

  def initialize(kind, name, source: SOURCE)
    @source = source
    @kind = kind
    @root = Dir.mktmpdir("sabun-#{kind}-")
    @evidence = File.join(SOURCE, 'tmp', 'quality', name)
    FileUtils.mkdir_p(@evidence)
    FileUtils.cp_r(File.join(SOURCE, 'test/fixtures/rails_app/.'), @root)
    FileUtils.mkdir_p(File.join(@root, 'tmp'))
    File.symlink(File.join(SOURCE, 'node_modules'), File.join(@root, 'node_modules')) if kind == 'playwright'
    @env = {
      'BUNDLE_GEMFILE' => File.join(@source, 'Gemfile'),
      'RUBYLIB' => [File.join(@source, 'lib'), ENV['RUBYLIB']].compact.join(File::PATH_SEPARATOR),
      'SABUN_ROOT' => @root, 'SABUN_SOURCE' => @source, 'SABUN_RUBY' => RbConfig.ruby,
      'SABUN_ENV_KEY' => 'quality-fixture-v1', 'RAILS_ENV' => 'test', 'RACK_ENV' => 'test',
      'SABUN_RECORD_FILE' => nil, 'SABUN_FIXTURE_RETRY' => nil,
      'SABUN_FIXTURE_SERVER_ROOT' => nil, 'SABUN_FIXTURE_FLAG' => nil,
      'SABUN_EXPECTED_IDENTITY' => nil, 'SABUN_CONFIG_PATH' => nil,
      'SABUN_E2E_TOKEN' => SecureRandom.hex(24), 'SABUN_E2E_URL_TEMPLATE' => nil
    }
    @suite = if kind == 'rspec'
      { 'id' => kind, 'kind' => kind, 'glob' => 'spec/requests/**/*_spec.rb',
        'command' => [RbConfig.ruby, Gem.bin_path('bundler', 'bundle'), 'exec', 'rspec',
                      '--format', 'json', '--out', 'tmp/rspec-result.json'] }
    else
      { 'id' => kind, 'kind' => kind, 'glob' => 'e2e/**/*.spec.js', 'projects' => ['chromium'],
        'command' => [File.join(SOURCE, 'node_modules/.bin/playwright'), 'test'] }
    end
    write('sabun.json', JSON.pretty_generate('suites' => [@suite], 'environment_variables' => ['SABUN_FIXTURE_FLAG']))
    git('init', '-q')
    git('config', 'user.name', 'Sabun Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    commit('fixture baseline')
    @step = 0
  end

  def close
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def read(path)
    File.read(File.join(@root, path))
  end

  def write(path, content)
    file = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, content)
  end

  def git(*args)
    stdout, stderr, status = Open3.capture3('git', '-C', @root, *args)
    raise "git #{args.first}: #{stderr}" unless status.success?
    stdout.strip
  end

  def commit(message)
    git('add', '.')
    git('commit', '-qm', message)
  end

  def baseline
    JSON.parse(read('tmp/baseline.json'))
  end

  def record(label = 'record', env: {})
    cli(label, 'record', '--all', '--out', 'tmp/baseline.json', env: env)
  end

  def plan(label, env: {})
    result = cli(label, 'plan', '--baseline', 'tmp/baseline.json', '--out', 'tmp/plan.json', env: env)
    raise "plan failed: #{diagnostic(result)}" unless result.status == 0
    data = JSON.parse(read('tmp/plan.json'))
    File.write(File.join(@evidence, "#{label}.json"), JSON.pretty_generate(data))
    data
  end

  def run_selected(label, env: {})
    cli(label, 'run', '--plan', 'tmp/plan.json', env: env)
  end

  def run_all(label, env: {})
    command(label, *@suite.fetch('command'), env: env)
  end

  def cli(label, *args, env: {})
    command(label, RbConfig.ruby, File.join(@source, 'bin/sabun'), *args, env: env)
  end

  def command(label, *argv, env: {})
    @step += 1
    prefix = format('%03d-%s', @step, label)
    report_path = File.join(@root, 'tmp', kind == 'rspec' ? 'rspec-result.json' : 'playwright-result.json')
    FileUtils.rm_f(report_path)
    stdout = stderr = nil
    status = nil
    Open3.popen3(@env.merge(env), *argv, chdir: @root, pgroup: true) do |stdin, out, err, wait|
      stdin.close
      readers = [Thread.new { out.read }, Thread.new { err.read }]
      begin
        Timeout.timeout(240) { status = wait.value.exitstatus }
      ensure
        if wait.alive?
          Process.kill('TERM', -wait.pid) rescue Errno::ESRCH
          unless wait.join(2)
            Process.kill('KILL', -wait.pid) rescue Errno::ESRCH
          end
        end
        stdout, stderr = readers.map(&:value)
      end
    end
    log = "$ #{argv.join(' ')}\nexit=#{status}\n#{stdout}\n#{stderr}"
    File.write(File.join(@evidence, "#{prefix}.log"), log.gsub(@env.fetch('SABUN_E2E_TOKEN'), '[REDACTED]'))
    report = File.file?(report_path) ? JSON.parse(File.read(report_path)) : nil
    FileUtils.cp(report_path, File.join(@evidence, "#{prefix}.json")) if report
    if kind == 'playwright'
      Dir.glob(File.join(@root, 'tmp', 'rails-worker-*.log')).each { |f| FileUtils.cp(f, @evidence) }
      workers = File.join(@root, 'tmp/workers.jsonl')
      FileUtils.cp(workers, File.join(@evidence, "#{prefix}-workers.jsonl")) if File.file?(workers)
    end
    Result.new(status: status, stdout: stdout, stderr: stderr, report: report, label: label)
  end

  def diagnostic(result)
    "#{result.label}: exit #{result.status}\n#{result.stdout}\n#{result.stderr}".slice(-12_000, 12_000) ||
      "#{result.label}: exit #{result.status}\n#{result.stdout}\n#{result.stderr}"
  end

  def examples(result)
    raise "test report missing: #{diagnostic(result)}" unless result.report
    if kind == 'rspec'
      result.report.fetch('examples').map do |example|
        { 'id' => example.fetch('full_description'),
          'unit' => example.fetch('file_path').delete_prefix('./'),
          'status' => example.fetch('status') }
      end
    else
      collect = lambda do |suites|
        suites.flat_map do |group|
          own = group.fetch('specs', []).flat_map do |spec|
            spec.fetch('tests').map do |test|
              file = spec.fetch('file')
              file = "e2e/#{file}" unless file.start_with?('e2e/')
              { 'id' => "#{File.basename(file)}:#{spec.fetch('title')}:#{test.fetch('projectName')}",
                'unit' => "#{file}::#{test.fetch('projectName')}",
                'status' => test.fetch('results').last&.fetch('status'),
                'attempts' => test.fetch('results') }
            end
          end
          own + collect.call(group.fetch('suites', []))
        end
      end
      collect.call(result.report.fetch('suites'))
    end
  end
end

module SelectionQualityAssertions
  def failed_example_ids(examples)
    # Playwrightの操作不能はtimedOutでも返る。通常の失敗と同じく見逃しを比較する。
    unexpected = examples.reject { |example| %w[passed failed timedOut].include?(example['status']) }
    assert_empty unexpected, 'skipped, interrupted or missing results must not count as completed verification'
    examples.reject { |example| example['status'] == 'passed' }.map { |example| example['id'] }.sort
  end

  def assert_recorded(project)
    recorded = project.record
    assert_equal 0, recorded.status, project.diagnostic(recorded)
    examples = project.examples(recorded)
    assert_operator examples.size, :>=, 3
    assert examples.all? { |e| e['status'] == 'passed' }, examples.inspect
    map = project.baseline
    assert_equal true, map['complete']
    units = map.fetch('units').fetch(project.kind)
    assert_equal examples.map { |e| e['unit'] }.uniq.sort, units.keys.sort
    assert units.values.all? { |u| u['complete'] == true }
    checkout = units.find { |id, _| id.include?('checkout') }.last
    shipping = units.find { |id, _| id.include?('shipping') }.last
    order = units.find { |id, _| id.include?('order') }.last
    assert_includes checkout['dependencies'], 'app/services/price.rb'
    refute_includes shipping['dependencies'], 'app/services/price.rb'
    assert_includes order['dependencies'], 'app/jobs/receipt_job.rb'
    assert_includes checkout['dependencies'], 'app/services/boot_label.rb'
    examples
  end

  def assert_no_change_is_skipped(project)
    selection = project.plan('no-change-plan').fetch('suites').fetch(project.kind)
    assert_empty selection['selected']
    assert_equal 0, project.run_selected('no-change-run').status
  end

  def assert_mutation(project, original_examples, name:, path:, from:, to:, broad: false)
    original = project.read(path)
    assert_includes original, from, "mutation target missing: #{path}"
    project.write(path, original.sub(from, to))
    project.commit("mutation: #{name}")
    begin
      plan = project.plan("#{name}-plan")
      selection = plan.fetch('suites').fetch(project.kind)
      selected_units = selection.fetch('selected')
      refute_empty selected_units, "#{name}: regression was skipped"
      if broad
        assert_equal original_examples.map { |e| e['unit'] }.uniq.sort, selected_units.sort
      elsif name != 'boot-value'
        refute selected_units.any? { |unit| unit.include?('shipping') }, "#{name}: unrelated test was selected"
      end
      selected = project.run_selected("#{name}-selected")
      full = project.run_all("#{name}-full")
      assert_equal 2, selected.status, project.diagnostic(selected)
      assert_equal 1, full.status, project.diagnostic(full)
      actual_selected = project.examples(selected)
      actual_full = project.examples(full)
      assert_equal selected_units.sort, actual_selected.map { |e| e['unit'] }.uniq.sort
      assert_equal original_examples.map { |e| e['id'] }.sort, actual_full.map { |e| e['id'] }.sort
      full_failures = failed_example_ids(actual_full)
      selected_failures = failed_example_ids(actual_selected)
      refute_empty full_failures, "#{name}: full run did not detect the intended defect"
      assert_equal full_failures, selected_failures, "#{name}: failing examples were lost"
      if name == 'price'
        assert_operator actual_selected.size, :<, actual_full.size, 'always-run-all is not a valid optimization'
      end
    ensure
      project.write(path, original)
      project.commit("restore after #{name}")
    end
  end

  def assert_unused_change_is_skipped(project, original_examples)
    path = 'app/services/unused.rb'
    original = project.read(path)
    project.write(path, original.sub('    1', '    2'))
    project.commit('change unused method')
    begin
      selection = project.plan('unused-plan').fetch('suites').fetch(project.kind)
      assert_empty selection['selected']
      assert_equal 0, project.run_selected('unused-selected').status
      full = project.run_all('unused-full')
      assert_equal 0, full.status, project.diagnostic(full)
      assert_equal original_examples.size, project.examples(full).size
      assert project.examples(full).all? { |e| e['status'] == 'passed' }
    ensure
      project.write(path, original)
      project.commit('restore unused method')
    end
  end

  def assert_environment_change(project, original_examples)
    env = { 'SABUN_FIXTURE_FLAG' => 'broken' }
    plan = project.plan('environment-plan', env: env)
    selection = plan.fetch('suites').fetch(project.kind)
    assert_equal original_examples.map { |e| e['unit'] }.uniq.sort, selection['selected'].sort
    full = project.run_all('environment-full', env: env)
    selected = project.run_selected('environment-selected', env: env)
    assert_equal 1, full.status, project.diagnostic(full)
    assert_equal 2, selected.status, project.diagnostic(selected)
    failures = failed_example_ids(project.examples(full))
    refute_empty failures
    assert_equal failures, failed_example_ids(project.examples(selected))
  end

  def core_mutations
    [
      { name: 'price', path: 'app/services/price.rb', from: '1200', to: '900' },
      { name: 'job', path: 'app/jobs/receipt_job.rb', from: "'paid'", to: "'broken'" },
      { name: 'boot-value', path: 'app/services/boot_label.rb', from: "'ready'", to: "'broken'" },
      { name: 'callback', path: 'app/controllers/checkouts_controller.rb',
        from: "class CheckoutsController < ActionController::Base\n",
        to: "class CheckoutsController < ActionController::Base\n  before_action :deny_requests\n", broad: true },
      { name: 'template', path: 'app/views/checkouts/show.html.erb',
        from: '<h1>Checkout</h1>', to: '<h1>Broken</h1>', broad: true }
    ]
  end
end
