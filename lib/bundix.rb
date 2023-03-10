# frozen_string_literal: true

require 'json'
require 'open-uri'
require 'open3'

require_relative 'bundix/dependency'
require_relative 'bundix/version'
require_relative 'bundix/source'
require_relative 'bundix/nixer'

platform_mapping = {}

{
  'ruby' => [{ engine: 'ruby' }, { engine: 'rbx' }, { engine: 'maglev' }],
  'mri' => [{ engine: 'ruby' }, { engine: 'maglev' }],
  'rbx' => [{ engine: 'rbx' }],
  'jruby' => [{ engine: 'jruby' }],
  'mswin' => [{ engine: 'mswin' }],
  'mswin64' => [{ engine: 'mswin64' }],
  'mingw' => [{ engine: 'mingw' }],
  'truffleruby' => [{ engine: 'ruby' }],
  'x64_mingw' => [{ engine: 'mingw' }]
}.each do |name, list|
  platform_mapping[name] = list
  %w[1.8 1.9 2.0 2.1 2.2 2.3 2.4 2.5 2.6 2.7 3.0 3.1 3.2].each do |version|
    platform_mapping["#{name}_#{version.sub(/[.]/, '')}"] = list.map do |platform|
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

  attr_reader :options, :old_gemset
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
    @old_gemset = parse_gemset
  end

  # Convert the content of Gemfile.lock to bundix's output schema
  def convert
    gemfile, lockfile = options.values_at(:gemfile, :lockfile)
    deps, lock = parse_gemfiles(gemfile, lockfile)

    gems = Hash.new { |h, k| h[k] = [] }

    lock.specs.each do |spec|
      gem = cached_gemspec(spec) || build_gemspec(spec, deps)
      # gem = build_gemspec(spec, deps)
      gem['dependencies'] = spec.dependencies.map(&:name) - ['bundler'] if spec.dependencies.any?
      gems[spec.name] << gem
    end

    gems.to_h do |name, variants|
      primary = nil
      targets = []
      variants.each do |v|
        target = v.dig('source', 'target')
        if (target == 'ruby') || target.nil?
          primary = v
          primary['source']['target'] = 'ruby' if target.nil?
        else
          targets << v['source']
        end
      end
      if primary.nil?
        spec = variants.first.clone
        spec['source'] = nil
        primary = spec
      end
      [name, primary.merge('targets' => targets)]
    end
  end

  private

  def build_gemspec(spec, deps)
    [platforms(spec, deps),
     groups(spec, deps),
     Source.new(spec, fetcher).convert].inject(&:merge)
  rescue StandardError => e
    warn "Skipping #{spec.name}: #{e}"
    puts e.backtrace
    {}
  end

  def cached_gemspec(spec)
    _, cached = old_gemset.find do |k, v|
      next unless k == spec.name
      next unless (cached_source = v['source'])

      case spec_source = spec.source
      when Bundler::Source::Git
        next unless cached_source['type'] == 'git'
        next unless (cached_rev = cached_source['rev'])
        next unless (spec_rev = spec_source.options['revision'])

        spec_rev == cached_rev
      when Bundler::Source::Rubygems
        next unless cached_source['type'] == 'gem'

        v['version'] == spec.version.to_s
      end
    end

    cached
  end

  def groups(spec, deps)
    { 'groups' => deps.fetch(spec.name).groups.map(&:to_s) }
  end

  def platforms(spec, deps)
    # c.f. Bundler::CurrentRuby
    platforms = deps.fetch(spec.name).platforms.map do |platform_name|
      platform_mapping[platform_name.to_s]
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
