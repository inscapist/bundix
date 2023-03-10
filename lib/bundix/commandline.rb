# frozen_string_literal: true

require 'English'
require 'optparse'
require 'tmpdir'
require 'tempfile'
require 'pathname'

require_relative '../bundix'
require_relative 'shell_nix_context'

class Bundix
  class CommandLine
    DEFAULT_OPTIONS = {
      ruby: 'ruby',
      bundle_pack_path: 'vendor/bundle',
      gemfile: 'Gemfile',
      lockfile: 'Gemfile.lock',
      gemset: 'gemset.nix',
      project: File.basename(Dir.pwd)
    }.freeze

    def self.run
      new.run
    end

    def initialize
      @options = DEFAULT_OPTIONS.clone
    end

    attr_accessor :options

    def run
      parse_options
      handle_magic
      handle_lock
      gemset = build_gemset
      save_gemset(gemset)
    end

    def parse_options
      op = OptionParser.new do |o|
        o.on '-m', '--magic', 'lock, pack, and write dependencies' do
          options[:magic] = true
        end

        o.on "--ruby=#{options[:ruby]}",
             'ruby version to use for magic and init, defaults to latest' do |value|
          options[:ruby] = value
        end

        o.on "--bundle-pack-path=#{options[:bundle_pack_path]}",
             'path to pack the magic' do |value|
          options[:bundle_pack_path] = value
        end

        o.on '-i', '--init',
             "initialize a new shell.nix for nix-shell (won't overwrite old ones)" do
          options[:init] = true
        end

        o.on "--gemset=#{options[:gemset]}", 'path to the gemset.nix' do |value|
          options[:gemset] = File.expand_path(value)
        end

        o.on "--lockfile=#{options[:lockfile]}", 'path to the Gemfile.lock' do |value|
          options[:lockfile] = File.expand_path(value)
        end

        o.on "--gemfile=#{options[:gemfile]}", 'path to the Gemfile' do |value|
          options[:gemfile] = File.expand_path(value)
        end

        o.on '-d', '--dependencies', 'include gem dependencies (deprecated)' do
          warn '--dependencies/-d is deprecated because'
          warn 'dependencies will always be fetched'
        end

        o.on '-q', '--quiet', 'only output errors' do
          options[:quiet] = true
        end

        o.on '-l', '--lock', 'generate Gemfile.lock first' do
          options[:lock] = true
        end

        o.on '-v', '--version', 'show the version of bundix' do
          puts Bundix::VERSION
          exit
        end

        o.on '--env', 'show the environment in bundix' do
          system('env')
          exit
        end
      end

      op.parse!
      $VERBOSE = !options[:quiet]
      options
    end

    def handle_magic
      ENV['BUNDLE_GEMFILE'] = options[:gemfile]

      return unless options[:magic]
      raise unless system(
        Bundix::NIX_SHELL, '-p', options[:ruby],
        "bundler.override { ruby = #{options[:ruby]}; }",
        '--command', "bundle lock --lockfile=#{options[:lockfile]}"
      )
      raise unless system(
        Bundix::NIX_SHELL, '-p', options[:ruby],
        "bundler.override { ruby = #{options[:ruby]}; }",
        '--command', "bundle pack --all --path #{options[:bundle_pack_path]}"
      )
    end

    def shell_nix_context
      ShellNixContext.from_hash(options)
    end

    def handle_lock
      return unless options[:lock]

      lock = !File.file?(options[:lockfile])
      lock ||= File.mtime(options[:gemfile]) > File.mtime(options[:lockfile])
      return unless lock

      ENV.delete('BUNDLE_PATH')
      ENV.delete('BUNDLE_FROZEN')
      ENV.delete('BUNDLE_BIN_PATH')
      system('bundle', 'lock')
      raise 'bundle lock failed' unless $CHILD_STATUS.success?
    end

    def build_gemset
      unless File.exist? 'Gemfile.lock'
        puts 'missing Gemfile.lock'
        return
      end

      Bundix.new(options).convert
    end

    def object2nix(obj)
      Nixer.serialize(obj)
    end

    def save_gemset(gemset)
      tempfile = Tempfile.new('gemset.nix', encoding: 'UTF-8')
      begin
        tempfile.write(object2nix(gemset))
        tempfile.flush
        FileUtils.cp(tempfile.path, options[:gemset])
        FileUtils.chmod(0o644, options[:gemset])
      ensure
        tempfile.close!
        tempfile.unlink
      end
    end
  end
end
