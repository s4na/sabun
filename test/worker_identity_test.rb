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
end
