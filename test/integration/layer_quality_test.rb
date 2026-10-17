# frozen_string_literal: true
require_relative 'fixture_project'

class LayerQualityTest < Minitest::Test
  include SelectionQualityAssertions

  def test_model_and_controller_specs_are_selected_with_real_rails
    project = FixtureProject.new('rspec', 'rails-layer-quality')
    begin
      model = 'app/models/order.rb'
      project.write(model, project.read(model).sub("  validates :status", "  def paid?\n    status == 'paid'\n  end\n\n  validates :status"))
      project.write('sabun.json', JSON.pretty_generate('suites' => [
        project.suite.merge('glob' => 'spec/**/*_spec.rb',
                            'command' => project.suite.fetch('command')[0...-1] + ['spec'])
      ], 'environment_variables' => ['SABUN_FIXTURE_FLAG']))
      project.commit('enable model and controller specs')
      original = assert_recorded(project)
      assert_equal 6, original.size
      units = project.baseline.fetch('units').fetch('rspec')
      assert_includes units.fetch('spec/layers/model_spec.rb').fetch('dependencies'), model
      assert_includes units.fetch('spec/layers/controller_spec.rb').fetch('dependencies'), 'app/controllers/checkouts_controller.rb'

      mutations = [
        { name: 'model-paid', path: model, from: "status == 'paid'", to: "status == 'pending'",
          expected: ['spec/layers/model_spec.rb'] },
        { name: 'controller-price', path: 'app/controllers/checkouts_controller.rb',
          from: '@price = Price.amount', to: '@price = 900',
          expected: ['spec/layers/controller_spec.rb', 'spec/requests/checkout_spec.rb'] }
      ]
      mutations.each do |mutation|
        path = mutation.fetch(:path)
        original_code = project.read(path)
        project.write(path, original_code.sub(mutation.fetch(:from), mutation.fetch(:to)))
        project.commit("break #{mutation.fetch(:name)}")
        begin
          plan = project.plan("#{mutation.fetch(:name)}-plan")
          selected_units = plan.fetch('suites').fetch('rspec').fetch('selected')
          mutation.fetch(:expected).each { |unit| assert_includes selected_units, unit }
          refute_includes selected_units, 'spec/requests/shipping_spec.rb'
          selected = project.run_selected("#{mutation.fetch(:name)}-selected")
          full = project.run_all("#{mutation.fetch(:name)}-full")
          assert_equal 2, selected.status, project.diagnostic(selected)
          assert_equal 1, full.status, project.diagnostic(full)
          assert_equal selected_units.sort, project.examples(selected).map { |e| e['unit'] }.uniq.sort
          failures = failed_example_ids(project.examples(full))
          refute_empty failures
          assert_equal failures, failed_example_ids(project.examples(selected))
          assert_operator project.examples(selected).size, :<, project.examples(full).size
        ensure
          project.write(path, original_code)
          project.commit("restore #{mutation.fetch(:name)}")
        end
      end
    ensure
      project.close
    end
  end
end
