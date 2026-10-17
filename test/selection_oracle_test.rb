# frozen_string_literal: true
require_relative 'integration/fixture_project'

class SelectionOracleTest < Minitest::Test
  include SelectionQualityAssertions

  def test_timeouts_are_not_lost_when_comparing_regressions
    examples = [
      { 'id' => 'assertion', 'status' => 'failed' },
      { 'id' => 'timeout', 'status' => 'timedOut' },
      { 'id' => 'success', 'status' => 'passed' }
    ]
    assert_equal %w[assertion timeout], failed_example_ids(examples)
  end

  def test_unfinished_results_are_not_accepted_as_completed_verification
    [nil, 'skipped', 'pending', 'interrupted'].each do |status|
      assert_raises(Minitest::Assertion) { failed_example_ids([{ 'id' => 'unfinished', 'status' => status }]) }
    end
  end
end
