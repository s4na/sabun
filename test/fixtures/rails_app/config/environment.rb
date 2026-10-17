# frozen_string_literal: true
ENV['RAILS_ENV'] ||= 'test'
require_relative 'application'
Rails.application.initialize!

# 外部DBを使わず、workerごとのSQLiteにschemaを作る。
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :orders, force: true do |table|
    table.string :status, null: false
  end
end
