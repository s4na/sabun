# frozen_string_literal: true
require 'bundler/setup' if ENV['BUNDLE_GEMFILE']
require_relative 'recorder'
Sabun::Recorder.start!
at_exit { Sabun::Recorder.finalize_rspec! }
require_relative 'rspec'
