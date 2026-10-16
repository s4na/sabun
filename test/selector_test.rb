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
      'schema_version' => 1, 'commit' => @base, 'fingerprint' => Sabun::Core.fingerprint,
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
    assert_equal 2, plan['suites']['spec']['selected'].size
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
end
