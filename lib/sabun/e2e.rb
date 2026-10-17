# frozen_string_literal: true
require 'json'
require 'thread'
require_relative 'recorder'

module Sabun
  module E2E
    class Middleware
      def initialize(app)
        @app = app
        @mutex = Mutex.new
        @active = 0
        @session = nil
        @worker_identity = Recorder.worker_identity
      end

      def call(env)
        return control(env) if env['PATH_INFO'] == '/__sabun__/control'
        @mutex.synchronize { @active += 1 }
        begin
          status, headers, body = @app.call(env)
          [status, headers, WrappedBody.new(body) { @mutex.synchronize { @active -= 1 } }]
        rescue Exception
          @mutex.synchronize { @active -= 1 }
          raise
        end
      end

      private

      def control(env)
        return respond(403, error: 'not enabled') unless ENV['SABUN_E2E_TOKEN'] && ENV['SABUN_E2E_JOBS_SYNC'] == '1'
        return respond(403, error: 'unauthorized') unless env['HTTP_AUTHORIZATION'] == "Bearer #{ENV.fetch('SABUN_E2E_TOKEN')}"
        return respond(405, error: 'POST required') unless env['REQUEST_METHOD'] == 'POST'
        data = JSON.parse(env.fetch('rack.input').read(4096))
        action = data['action']
        id = data['id'].to_s
        return respond(400, error: 'invalid id') if id.empty? || id.bytesize > 1024
        @mutex.synchronize do
          return respond(409, error: 'requests in flight') unless @active.zero?
          if data.key?('identity') && (@worker_identity.nil? || data['identity'] != @worker_identity)
            return respond(409, error: 'worker identity mismatch')
          end
          case action
          when 'start'
            return respond(409, error: 'overlapping test') if @session
            snapshot = Recorder.snapshot
            # 起動時に計算・保存された値は、リクエスト中に再実行されなくても依存する。
            @common ||= Recorder.changed({}, snapshot, methods_only: true)
            @session = { id: id, snapshot: snapshot }
            respond(200, ok: true, identity: @worker_identity)
          when 'finish'
            return respond(409, error: 'test ID mismatch') unless @session && @session[:id] == id
            dependencies = (@common | Recorder.changed(@session[:snapshot], Recorder.snapshot)).filter_map { |path| Core.relative(path) }
            @session = nil
            respond(200, dependencies: dependencies, identity: @worker_identity)
          else
            respond(400, error: 'unknown action')
          end
        end
      rescue JSON::ParserError, KeyError
        respond(400, error: 'invalid JSON')
      end

      def respond(status, data)
        body = JSON.generate(data)
        [status, { 'content-type' => 'application/json', 'content-length' => body.bytesize.to_s }, [body]]
      end

      class WrappedBody
        def initialize(body, &on_close)
          @body, @on_close, @closed = body, on_close, false
        end
        def each(&block)
          @body.each(&block)
        ensure
          close
        end
        def close
          return if @closed
          @closed = true
          @body.close if @body.respond_to?(:close)
          @on_close.call
        end
      end
    end
  end
end
