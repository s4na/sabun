# frozen_string_literal: true
require_relative 'lib/sabun/version'
Gem::Specification.new do |s|
  s.name = 'sabun'
  s.version = Sabun::VERSION
  s.summary = 'Conservative change-based test selection for Ruby, Rails and E2E suites'
  s.description = 'Record test dependencies and select affected tests with explicit safe fallbacks.'
  s.authors = ['sabun contributors']
  s.license = 'MIT'
  s.homepage = 'https://github.com/s4na/sabun'
  s.add_dependency 'prism', '>= 0.19'
  s.required_ruby_version = '>= 3.1'
  s.files = Dir['lib/**/*.rb', 'bin/*', 'README.md', 'LICENSE', 'playwright/*', 'examples/*', 'docs/*.md']
  s.bindir = 'bin'
  s.executables = ['sabun']
  s.require_paths = ['lib']
end
