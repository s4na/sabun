# frozen_string_literal: true
require_relative 'fixture_project'

# 実Railsの構造的変更は、過去のCoverageで未実行でもテスト結果を変える。
# 全件実行で検出できる回帰が選択実行で失われないことを検証する。
class RailsStructuralQualityTest < Minitest::Test
  include SelectionQualityAssertions

  def test_rails_structural_changes_preserve_all_failing_examples
    project = FixtureProject.new('rspec', 'rails-structural')
    begin
      baseline = assert_recorded(project)
      mutations = [
        { name: 'validation', path: 'app/models/order.rb',
          from: 'validates :status, presence: true',
          to: "validates :status, inclusion: { in: ['cancelled'] }", broad: true },
        { name: 'route', path: 'config/routes.rb',
          from: "get '/checkout', to: 'checkouts#show'",
          to: "get '/checkout', to: 'shipping#show'", broad: true },
        { name: 'controller-filter', path: 'app/controllers/checkouts_controller.rb',
          from: 'class CheckoutsController < ActionController::Base',
          to: "class CheckoutsController < ActionController::Base\n  before_action :deny_requests",
          broad: true },
        { name: 'initializer', path: 'config/initializers/boot_label.rb',
          from: 'Rails.configuration.x.boot_label = BootLabel.text',
          to: "Rails.configuration.x.boot_label = 'broken'", broad: true },
        { name: 'view', path: 'app/views/checkouts/show.html.erb',
          from: '<span id="price"><%= @price %></span>',
          to: '<span id="price">broken</span>', broad: true }
      ]
      mutations.each { |mutation| assert_mutation(project, baseline, **mutation) }
    ensure
      project.close
    end
  end
end
