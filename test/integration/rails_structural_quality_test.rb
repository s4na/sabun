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
        { name: 'default-scope', path: 'app/models/order.rb',
          from: 'class Order < ActiveRecord::Base',
          to: "class Order < ActiveRecord::Base\n  default_scope { where(status: 'cancelled') }",
          broad: true },
        { name: 'model-callback', path: 'app/models/order.rb',
          from: 'class Order < ActiveRecord::Base',
          to: "class Order < ActiveRecord::Base\n  before_save { raise 'blocked by callback' }",
          broad: true },
        { name: 'schema-column', path: 'config/environment.rb',
          from: 'table.string :status, null: false',
          to: 'table.string :state, null: false', broad: true },
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
  def test_controller_concern_method_change_selects_only_affected_request
    project = FixtureProject.new('rspec', 'rails-concern')
    begin
      project.write('app/controllers/concerns/checkout_label.rb', <<~RUBY)
        module CheckoutLabel
          def checkout_price
            Price.amount
          end
        end
      RUBY
      controller = 'app/controllers/checkouts_controller.rb'
      project.write(controller, project.read(controller)
        .sub('class CheckoutsController < ActionController::Base',
             "class CheckoutsController < ActionController::Base\n  include CheckoutLabel")
        .sub('@price = Price.amount', '@price = checkout_price'))
      project.commit('use Rails controller concern')
      baseline = assert_recorded(project)
      assert_mutation(project, baseline, name: 'concern-method',
                      path: 'app/controllers/concerns/checkout_label.rb',
                      from: 'Price.amount', to: '900')
    ensure
      project.close
    end
  end

end
