# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'
require 'open3'
require 'pathname'
require 'shellwords'
require 'set'

module Sabun
  class Error < StandardError; end
  module Core
    module_function

    def root
      File.expand_path(ENV.fetch('SABUN_ROOT', Dir.pwd))
    end

    def relative(path, base = root)
      absolute = File.expand_path(path, base)
      prefix = "#{File.expand_path(base)}/"
      absolute.start_with?(prefix) ? absolute.delete_prefix(prefix).tr('\\', '/') : nil
    end

    def git(*args, root: self.root)
      output, error, status = Open3.capture3('git', '-C', root, *args)
      raise Error, "git #{args.first}: #{error.strip}" unless status.success?
      output
    end

    def sha(ref = 'HEAD', root: self.root)
      git('rev-parse', '--verify', "#{ref}^{commit}", root: root).strip
    end

    def fingerprint(root: self.root, config: nil)
      keys = (%w[RUBYOPT RAILS_ENV RACK_ENV BUNDLE_GEMFILE SABUN_ENV_KEY] +
              (config || {}).fetch('environment_variables', [])).uniq.sort
      env = keys.to_h { |key| [key, ENV[key]] }
      if env['BUNDLE_GEMFILE']
        bundle_gemfile = File.expand_path(env['BUNDLE_GEMFILE'], root)
        env['BUNDLE_GEMFILE'] = relative(bundle_gemfile, root) || bundle_gemfile
      end
      # 計測用loaderだけは実行条件の差にしない。その他のRubyオプションは保持する。
      env['RUBYOPT'] = env['RUBYOPT'].to_s.split.reject do |option|
        %w[-rsabun/boot -rsabun/e2e/boot].include?(option)
      end.join(' ')
      files = %w[Gemfile.lock .ruby-version package-lock.json yarn.lock pnpm-lock.yaml]
      files << "#{File.expand_path(ENV['BUNDLE_GEMFILE'], root)}.lock" if ENV['BUNDLE_GEMFILE']
      digests = files.to_h do |path|
        absolute = File.expand_path(path, root)
        key = relative(absolute, root) || absolute
        [key, File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil]
      end
      ignored_sources = ignored_source_digests(root: root)
      Digest::SHA256.hexdigest(JSON.generate([RUBY_ENGINE, RUBY_VERSION, env, digests, ignored_sources, config]))
    end

    def ignored_source_digests(root: self.root)
      extensions = %w[.rb .js .mjs .cjs .ts .tsx .jsx .css .scss .sass .erb .html .haml .slim .yml .yaml .json .sql]
      excluded = %w[node_modules vendor/bundle vendor/cache .bundle tmp log coverage test-results .git]
      paths = git('ls-files', '--others', '--ignored', '--exclude-standard', '-z', root: root)
                .split("\0").select do |path|
        extensions.include?(File.extname(path).downcase) &&
          excluded.none? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
      end
      paths.sort.to_h do |path|
        absolute = File.expand_path(path, root)
        [path, File.file?(absolute) ? Digest::SHA256.file(absolute).hexdigest : nil]
      end
    rescue Error
      {}
    end

    def assert_clean!
      return if git('status', '--porcelain', '--untracked-files=all').strip.empty?
      raise Error, 'working tree must be clean, including untracked files'
    end

    def read_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, Errno::ENOENT => e
      raise Error, "invalid JSON #{path}: #{e.message}"
    end

    def write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"
      File.write(temporary, JSON.pretty_generate(data) + "\n")
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end

    def load_config(path = 'sabun.json', root: self.root)
      config = read_json(File.expand_path(path, root))
      raise Error, 'config requires suites array' unless config['suites'].is_a?(Array) && !config['suites'].empty?
      ids = config['suites'].map { |s| s.fetch('id') }
      raise Error, 'duplicate suite IDs' unless ids.uniq == ids
      variables = config.fetch('environment_variables', [])
      unless variables.is_a?(Array) && variables.all? { |name| name.is_a?(String) && name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) }
        raise Error, 'environment_variables must contain environment variable names'
      end
      config['suites'].each do |suite|
        raise Error, 'invalid suite' unless %w[rspec playwright].include?(suite['kind']) && suite['glob'].is_a?(String)
        raise Error, 'playwright suites require projects array' if suite['kind'] == 'playwright' && !(suite['projects'].is_a?(Array) && !suite['projects'].empty? && suite['projects'].all? { |p| p.is_a?(String) && !p.empty? })
        raise Error, 'missing command array' unless suite['command'].is_a?(Array) && suite['command'].all? { |x| x.is_a?(String) }
      end
      config
    end

    def inventory(config, root: self.root)
      config.fetch('suites').to_h do |suite|
        files = Dir.glob(File.join(root, suite.fetch('glob'))).select { |f| File.file?(f) }
        units = files.map { |f| relative(f, root) }.compact.sort
        units = suite.fetch('projects').flat_map { |project| units.map { |path| "#{path}::#{project}" } } if suite['kind'] == 'playwright'
        [suite.fetch('id'), units]
      end
    end

    def command!(argv, env: {}, root: self.root)
      raise Error, 'empty command' if argv.empty?
      system(env, *argv, chdir: root)
      status = $?.exitstatus || 1
      raise Error, "command failed (#{status}): #{argv.first}" unless status.zero?
      true
    end
  end
end
