# frozen_string_literal: true
require 'json'
require 'thread'
require_relative 'recorder'

module Sabun
  module E2E
    def self.register_worker(middleware)
      (@worker_middlewares ||= []) << middleware
    end

    # e2e/boot is preloaded before Rails application shutdown handlers. This
    # dispatcher therefore runs after those later-registered handlers.
    at_exit do
      Array(@worker_middlewares).each { |middleware| middleware.send(:finalize_worker!) }
    end

    class Middleware
      def initialize(app)
        @app = app
        @mutex = Mutex.new
        @active = 0
        @session = nil
        Recorder.start!
        @last_snapshot = Recorder.snapshot
        @common = nil
        @worker_identity = Recorder.worker_identity
        E2E.register_worker(self)
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
            if data.key?('identity')
              Recorder.capture_worker_identity!
              @worker_identity = Recorder.worker_identity
              return respond(409, error: 'worker identity mismatch') if @worker_identity.nil? || data['identity'] != @worker_identity
            end
            return respond(409, error: 'overlapping test') if @session
            snapshot = Recorder.snapshot
            # テスト間に実行されたRails処理も、後続unitに共通依存として帰属させる。
            @common |= Recorder.changed(@last_snapshot, snapshot) if @common
            # 起動時に計算・保存された値は、リクエスト中に再実行されなくても依存する。
            @common ||= Recorder.changed({}, snapshot, methods_only: true)
            @session = { id: id, snapshot: snapshot }
            @last_snapshot = snapshot
            respond(200, ok: true, identity: @worker_identity)
          when 'finish'
            return respond(409, error: 'test ID mismatch') unless @session && @session[:id] == id
            if data.key?('identity')
              Recorder.capture_worker_identity!
              @worker_identity = Recorder.worker_identity
              unless @worker_identity && data['identity'] == @worker_identity
                @session = nil
                return respond(409, error: 'worker identity mismatch')
              end
            end
            snapshot = Recorder.snapshot
            dependencies = (@common | Recorder.changed(@session[:snapshot], snapshot)).filter_map { |path| Core.relative(path) }
            @last_snapshot = snapshot
            @session = nil
            respond(200, dependencies: dependencies, identity: @worker_identity, worker_id: Process.pid)
          else
            respond(400, error: 'unknown action')
          end
        end
      rescue JSON::ParserError, KeyError
        respond(400, error: 'invalid JSON')
      end

      def finalize_worker!
        output = ENV['SABUN_RECORD_FILE']
        return unless output

        @mutex.synchronize do
          return if @session
          snapshot = Recorder.snapshot
          Recorder.capture_worker_identity!
          identity = Recorder.worker_identity
          dependencies = ((@common || []) | Recorder.changed(@last_snapshot, snapshot)).filter_map { |path| Core.relative(path) }
          directory = "#{output}.d"
          FileUtils.mkdir_p(directory)
          filename = File.join(directory, "worker-#{Process.pid}.json")
          Core.write_json(filename, {
            'kind' => 'worker_final', 'worker_id' => Process.pid,
            'complete' => @active.zero? && identity == @worker_identity && !identity.nil?,
            'dependencies' => dependencies, 'identity' => identity
          })
        end
      rescue StandardError
        # Finalization failure must be visible as a missing worker marker to the CLI.
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
