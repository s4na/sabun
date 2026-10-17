# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'rbconfig'

class E2EBootDependencyTest < Minitest::Test
  def test_startup_method_dependencies_belong_to_every_session
    Dir.mktmpdir('sabun-boot-') do |root|
      File.write(File.join(root, 'boot_value.rb'), "module BootValue\n  def self.text\n    'ready'\n  end\nend\n")
      File.write(File.join(root, 'run.rb'), <<~RUBY)
        require 'sabun/e2e'
        require 'stringio'
        require_relative 'boot_value'
        value = BootValue.text
        app = Sabun::E2E::Middleware.new(->(_) { [200, {}, [value]] })
        sessions = 2.times.map do |index|
          call = lambda do |action|
            app.call('PATH_INFO' => '/__sabun__/control', 'REQUEST_METHOD' => 'POST',
              'HTTP_AUTHORIZATION' => 'Bearer test-token',
              'rack.input' => StringIO.new(JSON.generate(action: action, id: index.to_s)))
          end
          raise 'start failed' unless call.call('start')[0] == 200
          response = app.call('PATH_INFO' => '/')
          response[2].each { |_| }
          JSON.parse(call.call('finish')[2].join).fetch('dependencies')
        end
        puts JSON.generate(sessions)
      RUBY
      lib = File.expand_path('../lib', __dir__)
      out, err, status = Open3.capture3(
        { 'SABUN_ROOT' => root, 'SABUN_E2E_TOKEN' => 'test-token', 'SABUN_E2E_JOBS_SYNC' => '1' },
        RbConfig.ruby, '-I', lib, '-rsabun/e2e/boot', 'run.rb', chdir: root
      )
      assert status.success?, "#{out}\n#{err}"
      JSON.parse(out).each { |dependencies| assert_includes dependencies, 'boot_value.rb' }
    end
  end
end
