# frozen_string_literal: true

require 'bundler'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'

require_relative 'bundix/dependency'
require_relative 'bundix/version'
require_relative 'bundix/source'
require_relative 'bundix/nixer'

PLATFORM_MAPPING = {
  'ruby' => [{ engine: 'ruby' }, { engine: 'rbx' }, { engine: 'maglev' }],
  'mri' => [{ engine: 'ruby' }, { engine: 'maglev' }],
  'rbx' => [{ engine: 'rbx' }],
  'jruby' => [{ engine: 'jruby' }],
  'mswin' => [{ engine: 'mswin' }],
  'mswin64' => [{ engine: 'mswin64' }],
  'mingw' => [{ engine: 'mingw' }],
  'truffleruby' => [{ engine: 'ruby' }],
  'x64_mingw' => [{ engine: 'mingw' }],
  'windows' => [{ engine: 'mswin' }, { engine: 'mswin64' }, { engine: 'mingw' }]
}.each_with_object({}) do |(name, list), mappings|
  mappings[name] = list
  %w[1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6 2.7 3.0 3.1 3.2 3.3].each do |version|
    mappings["#{name}_#{version.sub(/[.]/, '')}"] = list.map do |platform|
      platform.merge(version: version)
    end
  end
end

class Bundix
  NIX_INSTANTIATE = 'nix-instantiate'
  NIX_PREFETCH_URL = 'nix-prefetch-url'
  NIX_PREFETCH_GIT = 'nix-prefetch-git'
  NIX_HASH = 'nix-hash'
  NIX_SHELL = 'nix-shell'

  SHA256_32 = /^[a-z0-9]{52}$/.freeze

  attr_reader :options
  attr_accessor :fetcher

  def self.sh(*args, &block)
    out, status = Open3.capture2(*args)
    unless block_given? ? block.call(status, out) : status.success?
      puts "$ #{args.join(' ')}" if $VERBOSE
      puts out if $VERBOSE
      raise "command execution failed: #{status}"
    end
    out
  end

  def initialize(options)
    @options = { quiet: false, tempfile: nil }.merge(options)
    @fetcher = Fetcher.new
    @old_gemset = parse_gemset or {}
    gemfile, lockfile = @options.values_at(:gemfile, :lockfile)
    @gem_deps, @gem_lock = parse_gemfiles(gemfile, lockfile)
  end

  # Convert the content of Gemfile.lock to bundix's output schema
  def convert
    specs_by_name = Hash.new { |h, k| h[k] = [] }
    @gem_lock.specs.each do |spec|
      specs_by_name[spec.name] << spec
    end

    specs_by_name.transform_values do |specs|
      cached_gemspec(specs) || build_gemspec(specs)
    end
  end

  private

  def build_gemspec(specs)
    sources = specs.to_h do |spec|
      s = build_source(spec)
      target = s.dig('source', 'target') || 'ruby'
      [target, s]
    end

    isruby = proc { |k, _| k == 'ruby' }
    source_key = proc { |_, v| v['source'] }

    nix_obj = sources.first.last
                     .merge('targets' => sources.reject(&isruby).map(&source_key))
                     .merge('source' => sources.select(&isruby).map(&source_key).first)

    deps = specs.first.dependencies
    nix_obj['dependencies'] = deps.map(&:name) - ['bundler'] if deps.any?

    nix_obj
  end

  def build_source(spec)
    [platforms(spec),
     groups(spec),
     Source.new(spec, fetcher).convert].inject(&:merge)
  rescue StandardError => e
    warn "Skipping #{spec.name}: #{e}"
    puts e.backtrace
    {}
  end

  def cached_gemspec(specs)
    spec, = specs

    _, cached = @old_gemset.find do |k, v|
      next unless k == spec.name

      case spec_source = spec.source
      when Bundler::Source::Git
        next unless (old_source = v['source'])
        next unless old_source['type'] == 'git'
        next unless (cached_rev = old_source['rev'])
        next unless (spec_rev = spec_source.options['revision'])

        spec_rev == cached_rev
      when Bundler::Source::Rubygems
        next unless (v['targets'] + [v['source']]).compact.first['type'] == 'gem'

        # if changes are made to platform targets, recalculate
        old_targets = v['targets'].map { |i| i['target'] }
        old_targets << v.dig('source', 'target') if v['source']
        new_targets = specs.map(&:platform).map(&:to_s)

        next unless old_targets.sort == new_targets.sort

        v['version'] == spec.version.to_s
      end
    end

    cached
  end

  def groups(spec)
    { 'groups' => @gem_deps.fetch(spec.name).groups.map(&:to_s) }
  end

  def platforms(spec)
    # c.f. Bundler::CurrentRuby
    platforms = @gem_deps.fetch(spec.name).platforms.map do |platform_name|
      PLATFORM_MAPPING[platform_name.to_s]
    end.flatten

    { 'platforms' => platforms }
  end

  # Read existing gemset.nix if exists to reuse the computed hash
  def parse_gemset
    path = File.expand_path(options[:gemset])
    return {} unless File.file?(path)

    json = Bundix.sh(NIX_INSTANTIATE, '--eval', '-E', %(
      builtins.toJSON (import #{Nixer.serialize(path)})))
    JSON.parse(json.strip.gsub(/\\"/, '"')[1..-2])
  end
end
