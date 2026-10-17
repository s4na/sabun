# frozen_string_literal: true
require 'bundler/setup'
require 'sabun/e2e/boot'
require 'sabun/e2e'
require_relative 'config/environment'
require 'puma'

# Rails内部のstatic middlewareも含め、実際のHTTP処理を計測する。
app = Sabun::E2E::Middleware.new(Rails.application)
server = Puma::Server.new(app)
server.add_tcp_listener('127.0.0.1', Integer(ENV.fetch('PORT')))
%w[TERM INT].each { |signal| Signal.trap(signal) { server.stop } }
server.run.join
