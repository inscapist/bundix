# frozen_string_literal: true

require 'minitest/autorun'
require 'bundix'
require 'digest'
require 'json'

class TestConvert < Minitest::Test
  class PrefetchStub < Bundix::Fetcher
    def nix_prefetch_url(*args)
      format_hash(Digest::SHA256.hexdigest(args.to_s))
    end

    def nix_prefetch_git(*args)
      JSON.generate('sha256' => format_hash(Digest::SHA256.hexdigest(args.to_s)))
    end

    def fetch_remote_hash(spec, remote)
      hash = Digest::SHA256.hexdigest([remote, spec.full_name].join("::"))
      [hash, spec.platform&.to_s]
    end

    def spec_for_dependency(_remote, dependency)
      dependency
    end

    def fetch_local_hash(_spec)
      # Force to use fetch_remote_hash
      nil
    end
  end

  def with_gemset(options)
    Bundler.instance_variable_set(:@root, Pathname.new(File.expand_path('data', __dir__)))
    bundle_gemfile = ENV.fetch('BUNDLE_GEMFILE', nil)
    ENV['BUNDLE_GEMFILE'] = options[:gemfile]
    options = { deps: false, lockfile: '', gemset: '' }.merge(options)
    converter = Bundix.new(options)
    converter.fetcher = PrefetchStub.new
    yield(converter.convert)
  ensure
    ENV['BUNDLE_GEMFILE'] = bundle_gemfile
    Bundler.reset!
  end

  def expect_matches(gemset)
    # test local gem
    assert_equal(gemset.dig('phony_gem', 'version'), '0.1.0')
    assert_equal(gemset.dig('phony_gem', 'source', 'type'), 'path')
    assert_equal(gemset.dig('phony_gem', 'source', 'path'), 'lib/phony_gem')

    # test dependencies
    assert_includes(gemset.dig('nokogiri', 'dependencies'), 'racc')

    # test native gem
    assert_nil(gemset.dig('sqlite3', 'source'))

    # test targets
    actual_targets = gemset.dig('sqlite3', 'targets')
    assert_equal(actual_targets.map { |t| t['target'] }.sort, %w[arm64-darwin x64-mingw-ucrt x86_64-darwin x86_64-linux])
    assert_equal(actual_targets.map { |t| t['targetCPU'] }.sort, %w[arm64 x64 x86_64 x86_64])
    assert_equal(actual_targets.map { |t| t['targetOS'] }.sort, %w[darwin darwin linux mingw])
    assert_equal(actual_targets.map { |t| t['type'] }, %w[gem gem gem gem])

    # test git source
    assert_equal(gemset.dig('apparition', 'source', 'type'), 'git')
    assert_equal(gemset.dig('apparition', 'source', 'url'),
                 'https://github.com/twalpole/apparition.git')
    assert_equal(gemset.dig('apparition', 'source', 'rev'),
                 'ca86be4d54af835d531dbcd2b86e7b2c77f85f34')
    assert_equal(gemset.dig('apparition', 'source', 'fetchSubmodules'), false)
    assert_equal(gemset.dig('apparition', 'targets'), [])

    # test window alias expansion
    actual_targets = gemset.dig('io-console', 'platforms').map { |h| h.values.first }.sort
    assert_equal(actual_targets, %w[maglev mingw mswin mswin64 ruby])
  end


  def test_bundler_dep
    with_gemset(
      gemfile: File.expand_path('apps/rails-app/Gemfile', __dir__),
      lockfile: File.expand_path('apps/rails-app/Gemfile.lock', __dir__)
    ) do |gemset|
      expect_matches(gemset)
    end
  end

  def test_gemset_cache
    with_gemset(
      gemfile: File.expand_path('apps/rails-app/Gemfile', __dir__),
      lockfile: File.expand_path('apps/rails-app/Gemfile.lock', __dir__),
      gemset: File.expand_path('apps/rails-app/gemset.nix', __dir__)
    ) do |gemset|
      expect_matches(gemset)
    end
  end
end
