require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require_relative '../lib/sabun'

class RecorderTest < Minitest::Test
  def test_rspec_adapter_records_executed_file
    Dir.mktmpdir('sabun-recorder-') do |root|
      FileUtils.mkdir_p(File.join(root, 'rspec'))
      FileUtils.mkdir_p(File.join(root, 'app'))
      FileUtils.mkdir_p(File.join(root, 'spec'))
      File.write(File.join(root, 'app', 'price.rb'), "class Price\n  def self.value\n    10\n  end\nend\n")
      File.write(File.join(root, 'spec', 'price_spec.rb'), '# spec')
      File.write(File.join(root, 'rspec', 'core.rb'), <<~RUBY)
        module RSpec
          class Config
            attr_reader :before_suite, :around_each, :after_suite
            def before(kind, &block); @before_suite = block if kind == :suite; end
            def around(kind, &block); @around_each = block if kind == :each; end
            def after(kind, &block); @after_suite = block if kind == :suite; end
          end
          def self.configure(&block); block.call(config); end
          def self.config; @config ||= Config.new; end
        end
      RUBY
      File.write(File.join(root, 'runner.rb'), <<~RUBY)
        require_relative 'app/price'
        RSpec.config.before_suite.call
        example = Struct.new(:metadata, :exception) do
          def run; Price.value; end
        end.new({ file_path: 'spec/price_spec.rb' }, nil)
        RSpec.config.around_each.call(example)
        RSpec.config.after_suite.call
      RUBY
      output = File.join(root, 'record.json')
      loader = File.expand_path('../lib/sabun/boot', __dir__)
      env = { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output,
              'RUBYLIB' => root, 'RUBYOPT' => "-r#{loader}" }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, 'runner.rb', chdir: root)
      assert status.success?, "#{stdout}\n#{stderr}"
      data = JSON.parse(File.read(output))
      assert data['complete']
      assert_includes data.fetch('units').fetch('spec/price_spec.rb').fetch('dependencies'), 'app/price.rb'
    end
  end
end
