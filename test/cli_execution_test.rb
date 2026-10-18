require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require_relative '../lib/sabun'

class CLIExecutionTest < Minitest::Test
  def test_run_stops_before_the_next_playwright_project_if_checkout_changes
    Dir.mktmpdir('sabun-cli-execution-') do |root|
      previous_root = ENV['SABUN_ROOT']
      ENV['SABUN_ROOT'] = root
      git(root, 'init', '-q')
      git(root, 'config', 'user.name', 'Sabun Test')
      git(root, 'config', 'user.email', 'test@example.invalid')
      Dir.mktmpdir('sabun-cli-state-') do |state|
        log_path = File.join(state, 'projects.log')
        runner_path = File.join(state, 'runner.sh')
        File.write(runner_path, <<~SH)
          #!/bin/sh
          printf '%s\\n' "$1" >> "$SABUN_TEST_PROJECT_LOG"
          if [ "$1" = "--project=chromium" ]; then
            printf 'VALUE = 2\\n' > "$SABUN_ROOT/app.rb"
          fi
        SH
        File.chmod(0o755, runner_path)
        ENV['SABUN_TEST_RUNNER'] = runner_path
        ENV['SABUN_TEST_PROJECT_LOG'] = log_path
        FileUtils.mkdir_p(File.join(root, 'e2e'))
        File.write(File.join(root, 'e2e/checkout.spec.js'), 'test checkout')
        File.write(File.join(root, 'app.rb'), "VALUE = 1\n")
        config = {
          'environment_variables' => [],
          'suites' => [{ 'id' => 'browser', 'kind' => 'playwright', 'glob' => 'e2e/*.spec.js',
                         'projects' => %w[chromium firefox], 'command' => ['/bin/sh', runner_path] }]
        }
        config_path = File.join(root, 'sabun.json')
        File.write(config_path, JSON.generate(config))
        git(root, 'add', '.')
        git(root, 'commit', '-qm', 'baseline')
        head = Sabun::Core.sha
        plan_path = File.join(state, 'plan.json')
        Sabun::Core.write_json(plan_path, {
          'schema_version' => 1,
          'head' => head,
          'fingerprint' => Sabun::Core.fingerprint(config: config),
          'suites' => {
            'browser' => {
              'selected' => %w[e2e/checkout.spec.js::chromium e2e/checkout.spec.js::firefox],
              'skipped' => []
            }
          }
        })

        _stdout, stderr = capture_io do
          assert_equal 2, Sabun::CLI.start(['run', '--config', config_path, '--plan', plan_path])
        end

        assert_match(/working tree must be clean/, stderr)
        assert_equal "--project=chromium\n", File.read(log_path)
      ensure
        ENV.delete('SABUN_TEST_RUNNER')
        ENV.delete('SABUN_TEST_PROJECT_LOG')
      end
    ensure
      ENV['SABUN_ROOT'] = previous_root
    end
  end

  private

  def git(root, *args)
    output, error, status = Open3.capture3('git', '-C', root, *args)
    raise "git #{args.first} failed: #{error}" unless status.success?
    output
  end
end
