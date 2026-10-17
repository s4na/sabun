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
      core_mutations.each { |mutation| assert_mutation(project, examples, **mutation) }
      assert_unused_change_is_skipped(project, examples)
      assert_equal baseline_digest, Digest::SHA256.hexdigest(project.read('tmp/baseline.json'))
    ensure
      project.close
    end
  end
end
