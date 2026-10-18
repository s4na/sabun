require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'json'
require 'rubygems'

class RSpecIntegrationTest < Minitest::Test
  def test_real_rspec_collects_dependencies
    skip 'rspec-core is not installed' if Gem::Specification.find_all_by_name('rspec-core').empty?
    Dir.mktmpdir('sabun-rspec-') do |root|
      FileUtils.mkdir_p(File.join(root, 'app'))
      FileUtils.mkdir_p(File.join(root, 'spec'))
      File.write(File.join(root, 'app', 'calculator.rb'), "class Calculator\n  def self.add(a, b)\n    a + b\n  end\nend\n")
      File.write(File.join(root, 'spec', 'calculator_spec.rb'), <<~RUBY)
        require_relative '../app/calculator'
        RSpec.describe Calculator do
          it('adds') { expect(Calculator.add(1, 2)).to eq(3) }
        end
      RUBY
      loader = File.expand_path('../lib/sabun/boot', __dir__)
      output = File.join(root, 'record.json')
      env = { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output, 'RUBYOPT' => "-r#{loader}" }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-S', 'rspec', 'spec/calculator_spec.rb', chdir: root)
      assert status.success?, "#{stdout}\n#{stderr}"
      result = JSON.parse(File.read(output))
      assert result['complete']
      assert_includes result.fetch('units').fetch('spec/calculator_spec.rb').fetch('dependencies'), 'app/calculator.rb'
    end
  end
  def test_after_context_dependency_is_attributed_to_test_file
    skip 'rspec-core is not installed' if Gem::Specification.find_all_by_name('rspec-core').empty?
    Dir.mktmpdir('sabun-rspec-teardown-') do |root|
      FileUtils.mkdir_p(File.join(root, 'app'))
      FileUtils.mkdir_p(File.join(root, 'spec'))
      File.write(File.join(root, 'app', 'cleanup.rb'), <<~RUBY)
        class Cleanup
          def self.perform
            :cleaned
          end
        end
      RUBY
      File.write(File.join(root, 'spec', 'cleanup_spec.rb'), <<~RUBY)
        require_relative '../app/cleanup'
        RSpec.describe Cleanup do
          after(:context) { Cleanup.perform }
          it('runs an independent assertion') { expect(1).to eq(1) }
        end
      RUBY
      loader = File.expand_path('../lib/sabun/boot', __dir__)
      output = File.join(root, 'record.json')
      env = { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output, 'RUBYOPT' => "-r#{loader}" }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-S', 'rspec', 'spec/cleanup_spec.rb', chdir: root)
      assert status.success?, "#{stdout}\n#{stderr}"
      result = JSON.parse(File.read(output))
      assert result['complete']
      assert_includes result.fetch('units').fetch('spec/cleanup_spec.rb').fetch('dependencies'), 'app/cleanup.rb'
    end
  end

  def test_shutdown_hook_dependencies_are_captured_after_rspec_suite
    skip 'rspec-core is not installed' if Gem::Specification.find_all_by_name('rspec-core').empty?
    Dir.mktmpdir('sabun-rspec-shutdown-') do |root|
      FileUtils.mkdir_p(File.join(root, 'app'))
      FileUtils.mkdir_p(File.join(root, 'spec'))
      File.write(File.join(root, 'app', 'shutdown_cleanup.rb'), <<~RUBY)
        class ShutdownCleanup
          def self.perform
            :cleaned
          end
        end
      RUBY
      File.write(File.join(root, 'spec', 'shutdown_cleanup_spec.rb'), <<~RUBY)
        require_relative '../app/shutdown_cleanup'
        at_exit { ShutdownCleanup.perform }
        RSpec.describe ShutdownCleanup do
          it('runs an independent assertion') { expect(1).to eq(1) }
        end
      RUBY
      loader = File.expand_path('../lib/sabun/boot', __dir__)
      output = File.join(root, 'record.json')
      env = { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output, 'RUBYOPT' => "-r#{loader}" }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-S', 'rspec', 'spec/shutdown_cleanup_spec.rb', chdir: root)
      assert status.success?, "#{stdout}\n#{stderr}"
      result = JSON.parse(File.read(output))
      assert result['complete']
      assert_includes result.fetch('units').fetch('spec/shutdown_cleanup_spec.rb').fetch('dependencies'), 'app/shutdown_cleanup.rb'
    end
  end

end
