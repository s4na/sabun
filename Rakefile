require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.pattern = 'test/*_test.rb'
end

namespace :test do
  Rake::TestTask.new(:rails) do |t|
    t.pattern = 'test/integration/rails_quality_test.rb'
  end
  Rake::TestTask.new(:browser) do |t|
    t.pattern = 'test/integration/browser_quality_test.rb'
  end
end

task default: :test
