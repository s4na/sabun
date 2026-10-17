require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require_relative '../lib/sabun'

class QualityContractTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('sabun-quality-')
    @previous = ENV['SABUN_ROOT']
    ENV['SABUN_ROOT'] = @root
    git('init', '-q')
    git('config', 'user.name', 'Sabun Test')
    git('config', 'user.email', 'test@example.invalid')
    write('app/service.rb', "class Service\n  def self.value\n    1\n  end\nend\n")
    write('spec/service_spec.rb', '# test')
    write('spec/other_spec.rb', '# test')
    git('add', '.')
    git('commit', '-qm', 'baseline')
    @base = Sabun::Core.sha
    @config = { 'suites' => [{ 'id' => 'spec', 'kind' => 'rspec', 'glob' => 'spec/*_spec.rb', 'command' => ['ruby', '-v'] }] }
    @baseline = File.join(@root, 'baseline.json')
    save_map
  end

  def teardown
    ENV['SABUN_ROOT'] = @previous
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    Sabun::Core.git(*args, root: @root)
  end

  def write(path, content)
    dest = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(dest, content)
  end

  def save_map(overrides = {})
    Sabun::Core.write_json(@baseline, {
      'schema_version' => 1, 'commit' => @base, 'complete' => true,
      'fingerprint' => Sabun::Core.fingerprint(config: @config), 'suite_ids' => ['spec'],
      'units' => { 'spec' => {
        'spec/service_spec.rb' => { 'complete' => true, 'dependencies' => ['app/service.rb'] },
        'spec/other_spec.rb' => { 'complete' => true, 'dependencies' => [] }
      } }
    }.merge(overrides))
  end

  def selected
    Sabun::Selector.new.plan(config: @config, baseline_path: @baseline)['suites']['spec']['selected']
  end

  def commit(path, content)
    write(path, content)
    git('add', path)
    git('commit', '-qm', 'change')
  end

  def test_new_ruby_file_must_not_be_ignored
    commit('app/new_service.rb', "class NewService; end\n")
    assert_equal 2, selected.size
  end

  def test_deleted_file_must_not_be_ignored
    File.delete(File.join(@root, 'app/service.rb'))
    git('add', '-u')
    git('commit', '-qm', 'delete')
    assert_equal 2, selected.size
  end

  def test_route_change_must_select_all
    commit('config/routes.rb', "Rails.application.routes.draw { get '/x', to: 'x#index' }\n")
    assert_equal 2, selected.size
  end

  def test_js_change_must_select_all
    commit('app/javascript/application.js', "console.log('changed')\n")
    assert_equal 2, selected.size
  end

  def test_unknown_baseline_commit_must_select_all
    save_map('commit' => '0' * 40)
    assert_equal 2, selected.size
  end

  def test_missing_dependency_data_must_not_be_skipped
    save_map('units' => { 'spec' => {
      'spec/service_spec.rb' => { 'complete' => true, 'dependencies' => ['app/service.rb'] },
      'spec/other_spec.rb' => { 'complete' => false, 'dependencies' => [] }
    } })
    assert_includes selected, 'spec/other_spec.rb'
  end

  def test_new_test_is_always_selected
    commit('spec/new_spec.rb', '# new')
    assert_includes selected, 'spec/new_spec.rb'
  end

  def test_same_code_with_incomplete_baseline_runs_all
    save_map('complete' => false)
    assert_equal 2, selected.size
  end

  def test_lockfile_dependency_upgrade_runs_all
    write('Gemfile.lock', "GEM\n  specs:\n    example (1.0.0)\n")
    git('add', 'Gemfile.lock')
    git('commit', '-qm', 'lock baseline')
    save_map('commit' => Sabun::Core.sha, 'fingerprint' => Sabun::Core.fingerprint)
    commit('Gemfile.lock', "GEM\n  specs:\n    example (2.0.0)\n")
    assert_equal 2, selected.size
  end

  def test_gemfile_dependency_change_runs_all
    commit('Gemfile', "gem 'example', '2.0'\n")
    assert_equal 2, selected.size
  end

  def test_uncommitted_lockfile_change_invalidates_baseline
    write('Gemfile.lock', "GEM\n  specs:\n    example (1.0.0)\n")
    git('add', 'Gemfile.lock')
    git('commit', '-qm', 'lock baseline')
    save_map('commit' => Sabun::Core.sha, 'fingerprint' => Sabun::Core.fingerprint)
    write('Gemfile.lock', "GEM\n  specs:\n    example (2.0.0)\n")
    assert_equal 2, selected.size
  end
end
