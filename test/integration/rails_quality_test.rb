# frozen_string_literal: true
require_relative 'fixture_project'

class RailsQualityTest < Minitest::Test
  include SelectionQualityAssertions

  def test_real_request_specs_preserve_regression_detection_while_skipping_unrelated_tests
    project = FixtureProject.new('rspec', 'rails-recall')
    begin
      examples = assert_recorded(project)
      baseline_digest = Digest::SHA256.hexdigest(project.read('tmp/baseline.json'))
      assert_no_change_is_skipped(project)
      assert_environment_change(project, examples)
      core_mutations.each { |mutation| assert_mutation(project, examples, **mutation) }
      assert_unused_change_is_skipped(project, examples)
      assert_equal baseline_digest, Digest::SHA256.hexdigest(project.read('tmp/baseline.json'))
    ensure
      project.close
    end
  end

  def test_recording_cannot_overwrite_a_baseline_after_a_tracked_file_changes
    project = FixtureProject.new('rspec', 'rails-dirty-record')
    begin
      assert_recorded(project)
      baseline = project.read('tmp/baseline.json')
      path = 'spec/requests/checkout_spec.rb'
      project.write(path, project.read(path) + <<~RUBY)
        RSpec.configure do |config|
          config.after(:suite) { File.write('app/services/unused.rb', "# modified during recording\\n") }
        end
      RUBY
      project.commit('write source after otherwise successful specs')
      result = project.record('reject-dirty-record')
      assert_equal 2, result.status, project.diagnostic(result)
      assert_match(/working tree must be clean/, result.stderr)
      assert project.examples(result).all? { |e| e['status'] == 'passed' }
      assert_equal baseline, project.read('tmp/baseline.json')
    ensure
      project.close
    end
  end

  def test_failed_full_suite_cannot_promote_a_baseline
    project = FixtureProject.new('rspec', 'rails-failed-record')
    begin
      assert_recorded(project)
      baseline = project.read('tmp/baseline.json')
      path = 'spec/requests/checkout_spec.rb'
      project.write(path, project.read(path) + <<~RUBY)
        RSpec.describe 'failed baseline guard' do
          it('fails') { expect(true).to eq(false) }
        end
      RUBY
      project.commit('add a failing example')

      result = project.record('reject-failed-record')

      assert_equal 2, result.status, project.diagnostic(result)
      assert_match(/command failed/, result.stderr)
      refute_empty project.examples(result).select { |example| example['status'] == 'failed' }
      assert_equal baseline, project.read('tmp/baseline.json')
    ensure
      project.close
    end
  end

  def test_recording_cannot_stamp_the_original_commit_after_head_moves
    project = FixtureProject.new('rspec', 'rails-head-moved')
    begin
      path = 'spec/requests/checkout_spec.rb'
      project.write(path, project.read(path) + <<~RUBY)
        RSpec.configure do |config|
          config.after(:suite) { system('git', 'commit', '--allow-empty', '-qm', 'head moved') or raise 'git failed' }
        end
      RUBY
      project.commit('move HEAD after otherwise successful specs')
      before = project.git('rev-parse', 'HEAD')
      result = project.record('reject-moved-head')
      assert_equal 2, result.status, project.diagnostic(result)
      assert_match(/checkout changed during recording/, result.stderr)
      refute_equal before, project.git('rev-parse', 'HEAD')
      assert project.examples(result).all? { |e| e['status'] == 'passed' }
      refute File.exist?(File.join(project.root, 'tmp/baseline.json'))
    ensure
      project.close
    end
  end

  def test_untracked_sources_are_rejected_before_planning_or_recording
    project = FixtureProject.new('rspec', 'rails-untracked')
    begin
      assert_recorded(project)
      baseline = project.read('tmp/baseline.json')
      project.plan('clean-plan')
      project.write('app/services/untracked.rb', 'class Untracked; end')
      results = [project.record('reject-untracked-record'),
                 project.cli('reject-untracked-plan', 'plan', '--baseline', 'tmp/baseline.json', '--out', 'tmp/plan.json'),
                 project.run_selected('reject-untracked-run')]
      results.each do |result|
        assert_equal 2, result.status, project.diagnostic(result)
        assert_match(/including untracked files/, result.stderr)
        assert_nil result.report
      end
      assert_equal baseline, project.read('tmp/baseline.json')
    ensure
      project.close
    end
  end

  def test_a_gem_path_containing_spaces_works_with_real_rspec
    Dir.mktmpdir('sabun gem with spaces ') do |source|
      %w[lib bin Gemfile Gemfile.lock sabun.gemspec].each do |path|
        FileUtils.cp_r(File.join(FixtureProject::SOURCE, path), source)
      end
      project = FixtureProject.new('rspec', 'rails-loader-spaces', source: source)
      begin
        # BUNDLE_PATHはRubyバージョン別ディレクトリを含まない基底パスを指定する。
        bundle_path = Bundler.settings.path
        bundle_env = if bundle_path.use_system_gems?
          { 'BUNDLE_PATH' => nil, 'BUNDLE_PATH__SYSTEM' => 'true' }
        else
          { 'BUNDLE_PATH' => File.expand_path(bundle_path.base_path, Bundler.root), 'BUNDLE_PATH__SYSTEM' => nil }
        end
        result = project.record('record-with-spaces', env: bundle_env)
        assert_equal 0, result.status, project.diagnostic(result)
        assert_equal 3, project.examples(result).size
        assert project.examples(result).all? { |e| e['status'] == 'passed' }
        assert_equal true, project.baseline['complete']
      ensure
        project.close
      end
    end
  end
end
