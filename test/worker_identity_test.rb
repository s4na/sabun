# frozen_string_literal: true
require 'minitest/autorun'
require 'tmpdir'
require 'open3'
require 'json'
require 'rbconfig'

class WorkerIdentityTest < Minitest::Test
  def test_worker_identity_remains_bound_to_the_boot_revision
    Dir.mktmpdir('sabun-worker-identity-') do |root|
      File.write(File.join(root, 'sabun.json'), JSON.generate('suites' => [
        { 'id' => 'spec', 'kind' => 'rspec', 'glob' => '*.rb', 'command' => ['ruby'] }
      ]))
      File.write(File.join(root, 'run.rb'), <<~RUBY)
        require 'sabun/e2e'
        require 'stringio'
        boot_identity = Sabun::Recorder.worker_identity
        raise 'identity not captured' unless boot_identity
        Sabun::Core.git('commit', '--allow-empty', '-qm', 'move after boot')
        current = boot_identity.merge('commit' => Sabun::Core.sha)
        app = Sabun::E2E::Middleware.new(->(_) { [200, {}, ['OK']] })
        response = app.call('PATH_INFO' => '/__sabun__/control', 'REQUEST_METHOD' => 'POST',
          'HTTP_AUTHORIZATION' => 'Bearer test-token',
          'rack.input' => StringIO.new(JSON.generate(action: 'start', id: 'test', identity: current)))
        puts JSON.generate(status: response[0], body: JSON.parse(response[2].join))
      RUBY
      [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid'],
       ['add', '.'], ['commit', '-qm', 'boot revision']].each do |args|
        _, err, status = Open3.capture3('git', '-C', root, *args)
        assert status.success?, err
      end
      lib = File.expand_path('../lib', __dir__)
      out, err, status = Open3.capture3(
        { 'SABUN_ROOT' => root, 'SABUN_E2E_TOKEN' => 'test-token', 'SABUN_E2E_JOBS_SYNC' => '1' },
        RbConfig.ruby, '-I', lib, '-rsabun/e2e/boot', 'run.rb', chdir: root
      )
      assert status.success?, "#{out}\n#{err}"
      response = JSON.parse(out)
      assert_equal 409, response['status']
      assert_equal 'worker identity mismatch', response['body']['error']
    end
  end

  def test_finish_rejects_a_worker_checkout_changed_during_the_session
    Dir.mktmpdir('sabun-worker-finish-') do |root|
      File.write(File.join(root, 'sabun.json'), JSON.generate('suites' => [
        { 'id' => 'spec', 'kind' => 'rspec', 'glob' => '*.rb', 'command' => ['ruby'] }
      ]))
      File.write(File.join(root, 'tracked.rb'), "VALUE = 1\n")
      File.write(File.join(root, 'run.rb'), <<~RUBY)
        require 'sabun/e2e'
        require 'stringio'
        identity = Sabun::Recorder.worker_identity
        app = Sabun::E2E::Middleware.new(->(_) do
          File.write('tracked.rb', "VALUE = 2\\n")
          [200, {}, ['OK']]
        end)
        control = lambda do |action|
          app.call('PATH_INFO' => '/__sabun__/control', 'REQUEST_METHOD' => 'POST',
            'HTTP_AUTHORIZATION' => 'Bearer test-token',
            'rack.input' => StringIO.new(JSON.generate(action: action, id: 'test', identity: identity)))
        end
        raise 'start rejected' unless control.call('start')[0] == 200
        response = app.call('PATH_INFO' => '/request')
        response[2].each { |_| }
        status, _, body = control.call('finish')
        puts JSON.generate(status: status, body: JSON.parse(body.join))
      RUBY
      [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid'],
       ['add', '.'], ['commit', '-qm', 'worker session']].each do |args|
        _, err, status = Open3.capture3('git', '-C', root, *args)
        assert status.success?, err
      end
      lib = File.expand_path('../lib', __dir__)
      out, err, status = Open3.capture3(
        { 'SABUN_ROOT' => root, 'SABUN_E2E_TOKEN' => 'test-token', 'SABUN_E2E_JOBS_SYNC' => '1' },
        RbConfig.ruby, '-I', lib, '-rsabun/e2e/boot', 'run.rb', chdir: root
      )

      assert status.success?, "#{out}\n#{err}"
      response = JSON.parse(out)
      assert_equal 409, response['status']
      assert_equal 'worker identity mismatch', response['body']['error']
    end
  end

  def test_worker_shutdown_records_dependencies_executed_after_the_last_session
    Dir.mktmpdir('sabun-worker-final-') do |root|
      File.write(File.join(root, 'sabun.json'), JSON.generate('suites' => [
        { 'id' => 'browser', 'kind' => 'playwright', 'glob' => '*.js', 'projects' => ['chromium'], 'command' => ['node'] }
      ]))
      File.write(File.join(root, 'cleanup.rb'), "module Cleanup; def self.run; 1; end; end\n")
      File.write(File.join(root, 'run.rb'), <<~RUBY)
        require 'sabun/e2e'
        require 'stringio'
        identity = Sabun::Recorder.worker_identity
        app = Sabun::E2E::Middleware.new(->(_) { [200, {}, ['OK']] })
        control = lambda do |action|
          app.call('PATH_INFO' => '/__sabun__/control', 'REQUEST_METHOD' => 'POST',
            'HTTP_AUTHORIZATION' => 'Bearer test-token',
            'rack.input' => StringIO.new(JSON.generate(action: action, id: 'test', identity: identity)))
        end
        raise 'start rejected' unless control.call('start')[0] == 200
        raise 'finish rejected' unless control.call('finish')[0] == 200
        at_exit do
          require_relative 'cleanup'
          Cleanup.run # Simulates application shutdown after Middleware initialization.
        end
      RUBY
      [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid'],
       ['add', '.'], ['commit', '-qm', 'worker final snapshot']].each do |args|
        _, err, status = Open3.capture3('git', '-C', root, *args)
        assert status.success?, err
      end
      lib = File.expand_path('../lib', __dir__)
      output = File.join(root, 'tmp', 'record')
      out, err, status = Open3.capture3(
        { 'SABUN_ROOT' => root, 'SABUN_RECORD_FILE' => output,
          'SABUN_E2E_TOKEN' => 'test-token', 'SABUN_E2E_JOBS_SYNC' => '1' },
        RbConfig.ruby, '-I', lib, '-rsabun/e2e/boot', 'run.rb', chdir: root
      )

      assert status.success?, "#{out}\n#{err}"
      final = Dir.glob("#{output}.d/worker-*.json").map { |path| JSON.parse(File.read(path)) }.fetch(0)
      assert_equal true, final['complete']
      assert_includes final['dependencies'], 'cleanup.rb'
    end
  end
end
