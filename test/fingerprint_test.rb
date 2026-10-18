# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require_relative '../lib/sabun'

class FingerprintTest < Minitest::Test
  def with_environment(values)
    old = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| ENV[key] = value }
  end

  def test_declared_environment_values_are_fingerprinted_without_exposing_them
    config = { 'environment_variables' => ['SABUN_TEST_FLAG'] }
    Dir.mktmpdir do |root|
      with_environment('SABUN_TEST_FLAG' => 'original') do
        before = Sabun::Core.fingerprint(root: root, config: config)
        ENV['SABUN_TEST_FLAG'] = 'changed-secret-value'
        after = Sabun::Core.fingerprint(root: root, config: config)
        refute_equal before, after
        assert_match(/\A[0-9a-f]{64}\z/, after)
      end
    end
  end

  def test_suite_configuration_changes_invalidate_the_fingerprint
    Dir.mktmpdir do |root|
      before = Sabun::Core.fingerprint(root: root, config: { 'project' => 'chromium' })
      after = Sabun::Core.fingerprint(root: root, config: { 'project' => 'firefox' })
      refute_equal before, after
    end
  end

  def test_only_sabun_loader_options_are_ignored
    Dir.mktmpdir do |root|
      with_environment('RUBYOPT' => nil) do
        before = Sabun::Core.fingerprint(root: root)
        ENV['RUBYOPT'] = '-rsabun/e2e/boot'
        assert_equal before, Sabun::Core.fingerprint(root: root)
        ENV['RUBYOPT'] = '-W0 -rsabun/e2e/boot'
        refute_equal before, Sabun::Core.fingerprint(root: root)
      end
    end
  end

  def test_external_bundle_lockfile_is_not_ignored
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |bundle|
        lock = File.join(bundle, 'Gemfile.lock')
        File.write(lock, 'original dependency set')
        with_environment('BUNDLE_GEMFILE' => File.join(bundle, 'Gemfile')) do
          before = Sabun::Core.fingerprint(root: root)
          File.write(lock, 'different dependency set')
          refute_equal before, Sabun::Core.fingerprint(root: root)
        end
      end
    end
  end

  def test_ignored_source_changes_invalidate_the_fingerprint
    Dir.mktmpdir do |root|
      system('git', '-C', root, 'init', '-q')
      File.write(File.join(root, '.gitignore'), "app/generated.rb\n")
      source = File.join(root, 'app/generated.rb')
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "class Generated; def self.value = 1; end\n")

      before = Sabun::Core.fingerprint(root: root)
      File.write(source, "class Generated; def self.value = 2; end\n")
      after = Sabun::Core.fingerprint(root: root)

      refute_equal before, after
    end
  end
end
