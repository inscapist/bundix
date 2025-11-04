# frozen_string_literal: true

class Bundix
  class Fetcher
    def sh(...)
      Bundix.sh(...)
    end

    def download(file, url, limit = 10)
      warn "Downloading #{file} from #{url}"
      uri = URI(url)

      case uri.scheme
      when nil # local file path
        FileUtils.cp(url, file)
      when 'http', 'https'
        unless uri.user
          inject_credentials_from_bundler_settings(uri)
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        if http.use_ssl?
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.verify_callback = lambda do |preverify_ok, store_context|
            # OpenSSL 3.2.3+ enforces CRL retrieval by default, which fails for
            # Rubygems' certificate chain. Treat "unable to get certificate CRL"
            # as non-fatal so TLS still succeeds.
            preverify_ok || store_context&.error == OpenSSL::X509::V_ERR_UNABLE_TO_GET_CRL
          end
        end

        http.start do |connection|
          request = Net::HTTP::Get.new(uri)
          if uri.user
            request.basic_auth(uri.user, uri.password)
          end

          connection.request(request) do |resp|
            case resp
            when Net::HTTPOK
              File.open(file, 'wb+') do |local|
                resp.read_body { |chunk| local.write(chunk) }
              end
            when Net::HTTPRedirection
              location = resp['location']
              raise "http error: Redirection loop detected" if location == url
              raise "http error: Too many redirects" if limit < 1

              warn "Redirected to #{location}"
              download(file, location, limit - 1)
            when Net::HTTPUnauthorized, Net::HTTPForbidden
              debrief_access_denied(uri.host)
              raise "http error #{resp.code}: #{uri.host}"
            else
              raise "http error #{resp.code}: #{uri.host}"
            end
          end
        end
      else
        raise "Unsupported URL scheme"
      end
    end

    def inject_credentials_from_bundler_settings(uri)
      # rubocop:disable all
      @bundler_settings ||= Bundler::Settings.new(Bundler.root + ".bundle")

      return unless (val = @bundler_settings[uri.host])

      uri.user, uri.password = val.split(":", 2)
    end

    def debrief_access_denied(host)
      print_error(
        "Authentication is required for #{host}.\n" \
        "Please supply credentials for this source. You can do this by running:\n" \
        " bundle config packages.shopify.io username:password"
      )
    end

    def print_error(msg)
      msg = "\x1b[31m#{msg}\x1b[0m" if $stdout.tty?
      warn(msg)
    end

    def nix_prefetch_url(url)
      dir = File.join(ENV["XDG_CACHE_HOME"] || "#{ENV["HOME"]}/.cache", "bundix")
      FileUtils.mkdir_p dir
      file = File.join(dir, url.gsub(/[^\w-]+/, "_"))

      download(file, url) unless File.size?(file)
      return unless File.size?(file)

      sh(
        Bundix::NIX_PREFETCH_URL,
        '--type', 'sha256',
        '--name', File.basename(url), # --name mygem-1.2.3.gem
        "file://#{file}",             # file:///.../https_rubygems_org_gems_mygem-1_2_3_gem
      ).force_encoding('UTF-8').strip
    rescue StandardError => ex
      STDERR.puts(ex.full_message)
      nil
    end

    def nix_prefetch_git(uri, revision, submodules: false)
      home = ENV["HOME"]
      ENV["HOME"] = "/homeless-shelter"

      uri_parsed = URI(uri)
      if %w[http https].include?(uri_parsed.scheme) && !uri_parsed.user
        inject_credentials_from_bundler_settings(uri_parsed)
        uri = uri_parsed.to_s
      end

      args = []
      args << "--url" << uri
      args << "--rev" << revision
      args << "--hash" << "sha256"
      args << "--fetch-submodules" if submodules

      sh(NIX_PREFETCH_GIT, *args)
    ensure
      ENV["HOME"] = home
    end

    NIX_BASE32 = "0123456789abcdfghijklmnpqrsvwxyz".freeze

    def format_hash(hash)
      value = hash.to_s.strip.downcase
      hex_re = /\A[0-9a-f]+\z/
      nix_base32_re = /\A[#{NIX_BASE32}]+\z/

      if value.match?(hex_re)
        expected_length = (value.length * 4 + 4) / 5
        return "0" * expected_length if value.match?(/\A0+\z/)

        # reverse-bytes before integer conversion to match nix tooling
        int_value = value.scan(/../).reverse.join.to_i(16)
        out = +""

        while int_value.positive?
          out << NIX_BASE32[int_value & 0x1f]
          int_value >>= 5
        end

        out.reverse.rjust(expected_length, "0")
      elsif value.match?(nix_base32_re)
        value
      else
        raise "Unsupported hash format: #{hash.inspect}"
      end
    end

    def fetch_local_hash(spec)
      platform = Gem::Platform::RUBY # default platform value
      has_platform = spec.platform && spec.platform != Gem::Platform::RUBY
      name_version = "#{spec.name}-#{spec.version}"
      filename = has_platform ? "#{name_version}-*" : name_version

      paths = spec.source.caches.map(&:to_s)
      Dir.glob("{#{paths.join(",")}}/#{filename}.gem").each do |path|
        if has_platform
          # Find first gem that matches the platform
          platform = File.basename(path, ".gem")[(name_version.size + 1)..]
          next unless spec.platform =~ platform
        end

        hash = nix_prefetch_url(path)&.[](SHA256_32)
        return format_hash(hash), platform if hash
      end

      nil
    end

    def fetch_remotes_hash(spec, remotes)
      remotes.each do |remote|
        hash, platform = fetch_remote_hash(spec, remote)
        return remote, format_hash(hash), platform if hash
      end

      nil
    end

    def fetch_remote_hash(spec, remote)
      has_platform = spec.platform && spec.platform != Gem::Platform::RUBY
      if has_platform
        # Fetch remote spec to determine the exact platform
        # Note that we can't simply use the local platform; the platform of the gem might differ.
        # e.g. universal-darwin-14 covers x86_64-darwin-14
        spec = spec_for_dependency(remote, spec)
      end

      uri = "#{remote}/gems/#{spec.full_name}.gem"
      result = nix_prefetch_url(uri)
      return unless result

      [result[SHA256_32], spec.platform&.to_s]
    rescue StandardError => e
      puts "ignoring error during fetching: #{e}"
      puts e.backtrace
      nil
    end

    # dep = Gem::Dependency.new("nokogiri", "1.14.0")
    # sources = Gem::SourceList.from(["https://rubygems.org"])
    # specs, _errors = Gem::SpecFetcher.new(sources).spec_for_dependency(dep, false)
    #
    # specs.map do |spec, source| p = spec.platform;
    #   (p.respond_to?(:cpu) ? [p.cpu, p.os, p.version] : p)
    # end
    def spec_for_dependency(remote, dependency)
      sources = Gem::SourceList.from([remote])
      dep = Gem::Dependency.new(dependency.name, dependency.version)
      match_current_platform = false
      specs, _errors = Gem::SpecFetcher.new(sources).spec_for_dependency(dep, match_current_platform)
      specs.each do |spec, _source|
        return spec if dependency.platform == spec.platform
      end
      raise "Unable to find compatible rubygem source for #{dependency.platform}."
    end
  end

  Source = Struct.new(:spec, :fetcher) do
    def convert
      case spec.source
      when Bundler::Source::Rubygems
        convert_rubygems
      when Bundler::Source::Git
        convert_git
      when Bundler::Source::Path
        convert_path
      else
        pp spec
        raise "unknown bundler source"
      end
    end

    def convert_path
      {
        "version" => spec.version.to_s,
        "source" => {
          "type" => "path",
          "path" => spec.source.path.to_s,
        },
      }
    end

    def convert_rubygems
      remotes = spec.source.remotes.map { |remote| remote.to_s.sub(%r{/+$}, "") }
      hash, platform = fetcher.fetch_local_hash(spec)
      remote, hash, platform = fetcher.fetch_remotes_hash(spec, remotes) unless hash
      raise "couldn't fetch hash for #{spec.full_name}" unless hash

      version = spec.version.to_s
      nixspec = {
        "version" => version,
        "source" => {
          "type" => "gem",
          "remotes" => (remote ? [remote] : remotes),
          "sha256" => hash,
          "target" => platform,
        },
      }
      native_platform = Gem::Platform.new(platform)
      if native_platform.respond_to? :cpu
        nixspec["source"]["targetCPU"] = native_platform.cpu
        nixspec["source"]["targetOS"] = native_platform.os
      end
      nixspec
    end

    def convert_git
      revision = spec.source.options.fetch("revision")
      uri = spec.source.options.fetch("uri")
      submodules = !spec.source.submodules.nil?
      output = fetcher.nix_prefetch_git(uri, revision, submodules: submodules)
      # FIXME: this is a hack, we should separate $stdout/$stderr in the sh call
      hash = JSON.parse(output[/({[^}]+})\s*\z/m])["sha256"]
      raise "couldn't fetch hash for #{spec.full_name}" unless hash

      puts "#{hash} => #{uri}" if $VERBOSE

      {
        "version" => spec.version.to_s,
        "source" => {
          "type" => "git",
          "url" => uri.to_s,
          "rev" => revision,
          "sha256" => hash,
          "fetchSubmodules" => submodules,
        },
      }
    end
  end
end
