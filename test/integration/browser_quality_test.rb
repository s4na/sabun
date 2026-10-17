# frozen_string_literal: true
require_relative 'fixture_project'

class BrowserQualityTest < Minitest::Test
  include SelectionQualityAssertions

  def test_real_chromium_and_rails_preserve_regression_detection
    project = FixtureProject.new('playwright', 'browser-recall')
    begin
      examples = assert_recorded(project)
      workers = project.read('tmp/workers.jsonl').lines.map { |line| JSON.parse(line) }
      assert_operator workers.map { |w| w['pid'] }.uniq.size, :>=, 2
      assert_operator workers.map { |w| w['url'] }.uniq.size, :>=, 2
      baseline_digest = Digest::SHA256.hexdigest(project.read('tmp/baseline.json'))
      assert_no_change_is_skipped(project)
      mutations = core_mutations + [
        { name: 'javascript', path: 'public/app.js', from: 'details ready', to: 'broken', broad: true },
        { name: 'css', path: 'public/app.css', from: 'display: inline', to: 'display: none', broad: true }
      ]
      mutations.each { |mutation| assert_mutation(project, examples, **mutation) }
      assert_unused_change_is_skipped(project, examples)
      assert_equal baseline_digest, Digest::SHA256.hexdigest(project.read('tmp/baseline.json'))
    ensure
      project.close
    end
  end

  def test_a_test_without_the_bridge_cannot_promote_an_incomplete_baseline
    project = FixtureProject.new('playwright', 'browser-missing-bridge')
    begin
      assert_recorded(project)
      original = project.read('tmp/baseline.json')
      project.write('e2e/uninstrumented.spec.js', <<~JS)
        const { test, expect } = require('@playwright/test');
        test('計測を使っていないテスト', async () => { expect(1).toBe(1); });
      JS
      project.commit('add an uninstrumented test')
      result = project.record('reject-missing-bridge')
      assert_equal 2, result.status, project.diagnostic(result)
      assert_match(/incomplete recording/, result.stderr)
      assert_equal original, project.read('tmp/baseline.json')
      assert project.examples(result).all? { |e| e['status'] == 'passed' }
    ensure
      project.close
    end
  end

  def test_retry_and_worker_restart_cannot_promote_partial_observations
    project = FixtureProject.new('playwright', 'browser-retry')
    begin
      result = project.record('reject-retry', env: { 'SABUN_FIXTURE_RETRY' => '1' })
      assert_equal 2, result.status, project.diagnostic(result)
      assert_match(/incomplete recording/, result.stderr)
      refute File.exist?(File.join(project.root, 'tmp/baseline.json'))
      retried = project.examples(result).find { |e| e.fetch('attempts').size == 2 }
      refute_nil retried, 'the fixture must really retry, not just return an error'
      assert_equal %w[failed passed], retried['attempts'].map { |a| a['status'] }
      assert_equal 2, retried['attempts'].map { |a| a['workerIndex'] }.uniq.size
    ensure
      project.close
    end
  end
end
