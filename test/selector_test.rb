require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/sabun'

class SelectorTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir('sabun-test-')
    @old_root = ENV['SABUN_ROOT']
    ENV['SABUN_ROOT'] = @dir
    git('init', '-q')
    git('config', 'user.name', 'Sabun Test')
    git('config', 'user.email', 'test@example.invalid')
    write('app/model.rb', "class Model\n  def price\n    1\n  end\nend\n")
    write('spec/a_spec.rb', '# a')
    write('spec/b_spec.rb', '# b')
    git('add', '.')
    git('commit', '-qm', 'base')
    @base = Sabun::Core.sha
    @config = { 'suites' => [{ 'id' => 'spec', 'kind' => 'rspec', 'glob' => 'spec/*_spec.rb', 'command' => ['ruby', '-v'] }] }
    @baseline = File.join(@dir, 'baseline.json')
    @units = {
      'spec/a_spec.rb' => { 'complete' => true, 'dependencies' => ['app/model.rb'] },
      'spec/b_spec.rb' => { 'complete' => true, 'dependencies' => [] }
    }
    save_baseline
  end

  def teardown
    ENV['SABUN_ROOT'] = @old_root
    FileUtils.remove_entry(@dir)
  end

  def git(*args)
    Sabun::Core.git(*args, root: @dir)
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def save_baseline(**overrides)
    Sabun::Core.write_json(@baseline, {
      'schema_version' => 1, 'commit' => @base, 'fingerprint' => Sabun::Core.fingerprint(config: @config),
      'suite_ids' => ['spec'], 'complete' => true, 'units' => { 'spec' => @units }
    }.merge(overrides))
  end

  def plan
    Sabun::Selector.new.plan(config: @config, baseline_path: @baseline)
  end

  def test_method_body_change_selects_only_dependent_spec
    write('app/model.rb', "class Model\n  def price\n    2\n  end\nend\n")
    git('add', 'app/model.rb'); git('commit', '-qm', 'change body')
    assert_equal 'ruby_body', plan['changes'].first['scope']
    assert_equal ['spec/a_spec.rb'], plan['suites']['spec']['selected']
    assert_equal ['spec/b_spec.rb'], plan['suites']['spec']['skipped']
  end

  def test_new_method_falls_back_to_full_suite
    write('app/model.rb', "class Model\n  def price\n    1\n  end\n  def discounted\n    true\n  end\nend\n")
    git('add', 'app/model.rb'); git('commit', '-qm', 'new method')
    assert_equal 'structural', plan['changes'].first['scope']
    assert_equal 2, plan['suites']['spec']['selected'].size
  end

  def test_missing_unit_is_never_skipped
    @units.delete('spec/b_spec.rb')
    save_baseline
    assert_includes plan['suites']['spec']['selected'], 'spec/b_spec.rb'
  end

  def test_changed_spec_is_selected
    write('spec/b_spec.rb', '# changed')
    git('add', 'spec/b_spec.rb'); git('commit', '-qm', 'spec change')
    assert_equal ['spec/b_spec.rb'], plan['suites']['spec']['selected']
  end

  def test_mismatched_fingerprint_runs_all
    save_baseline('fingerprint' => 'wrong')
    assert_equal 2, plan['suites']['spec']['selected'].size
    assert_includes plan['suites']['spec']['reasons']['spec/a_spec.rb'], 'environment_mismatch'
  end

  def test_unknown_schema_runs_all
    save_baseline('schema_version' => 999)
    assert_equal 2, plan['suites']['spec']['selected'].size
  end

  def test_empty_change_skips_observed_tests
    assert_empty plan['suites']['spec']['selected']
  end

  def test_nested_definition_change_is_structural
    write('app/model.rb', "class Model\n  def price\n    define_method(:secret) { 3 }\n  end\nend\n")
    git('add', 'app/model.rb'); git('commit', '-qm', 'dynamic method')
    assert_equal 'structural', plan['changes'].first['scope']
  end
  def test_changed_playwright_spec_selects_only_its_projects
    write('e2e/checkout.spec.js', 'test checkout')
    write('e2e/shipping.spec.js', 'test shipping')
    git('add', 'e2e')
    git('commit', '-qm', 'add browser specs')
    @base = Sabun::Core.sha
    @config = { 'suites' => [{ 'id' => 'browser', 'kind' => 'playwright',
      'glob' => 'e2e/*.spec.js', 'projects' => %w[chromium firefox], 'command' => ['npx', 'playwright', 'test'] }] }
    browser_units = %w[checkout shipping].product(%w[chromium firefox]).to_h do |name, project|
      ["e2e/#{name}.spec.js::#{project}", { 'complete' => true, 'dependencies' => [] }]
    end
    save_baseline('suite_ids' => ['browser'], 'units' => { 'browser' => browser_units })
    write('e2e/checkout.spec.js', 'test changed checkout')
    git('add', 'e2e/checkout.spec.js')
    git('commit', '-qm', 'change checkout spec')
    selection = plan.fetch('suites').fetch('browser')
    assert_equal %w[chromium firefox].map { |p| "e2e/checkout.spec.js::#{p}" }.sort, selection['selected'].sort
    assert_equal %w[chromium firefox].map { |p| "e2e/shipping.spec.js::#{p}" }.sort, selection['skipped'].sort
  end

  def test_test_file_changes_do_not_fan_out_across_suites
    write('e2e/checkout.spec.js', 'test checkout')
    git('add', 'e2e/checkout.spec.js')
    git('commit', '-qm', 'add browser spec')
    @base = Sabun::Core.sha
    @config = { 'suites' => [
      { 'id' => 'spec', 'kind' => 'rspec', 'glob' => 'spec/*_spec.rb', 'command' => ['ruby', '-v'] },
      { 'id' => 'browser', 'kind' => 'playwright', 'glob' => 'e2e/*.spec.js',
        'projects' => ['chromium'], 'command' => ['npx', 'playwright', 'test'] }
    ] }
    save_baseline(
      'suite_ids' => %w[spec browser],
      'units' => {
        'spec' => @units,
        'browser' => { 'e2e/checkout.spec.js::chromium' => { 'complete' => true, 'dependencies' => [] } }
      }
    )

    write('spec/a_spec.rb', '# changed')
    git('add', 'spec/a_spec.rb')
    git('commit', '-qm', 'change RSpec file')
    selection = plan.fetch('suites')

    assert_equal ['spec/a_spec.rb'], selection.fetch('spec').fetch('selected')
    assert_empty selection.fetch('browser').fetch('selected')
    assert_equal ['e2e/checkout.spec.js::chromium'], selection.fetch('browser').fetch('skipped')
  end

end
