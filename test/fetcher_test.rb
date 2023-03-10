# rubocop:disable all

require 'minitest/autorun'
require 'bundix'
require 'socket'
require 'tmpdir'
require 'base64'

class Bundix
  class FetcherTest < MiniTest::Test
    def test_download_with_credentials
      with_dir(bundler_credential: 'secret') do |dir|
        with_server(returning_content: 'ok') do |port|
          file = 'some-file'

          assert_equal(File.realpath(dir), Bundler.root.to_s)

          out, err = capture_io do
            Bundix::Fetcher.new.download(file, "http://127.0.0.1:#{port}/test")
          end

          assert_includes(@request, "Authorization: Basic #{Base64.encode64('secret:').chomp}")
          assert_equal(File.read(file), 'ok')
          assert_empty(out)
          assert_match(/^Downloading .* from http.*$/, err)
        end
      end
    end

    def test_download_without_credentials
      with_dir(bundler_credential: nil) do |dir|
        with_server(returning_content: 'ok') do |port|
          file = 'some-file'

          assert_equal(File.realpath(dir), Bundler.root.to_s)

          out, err = capture_io do
            Bundix::Fetcher.new.download(file, "http://127.0.0.1:#{port}/test")
          end

          refute_includes(@request, 'Authorization:')
          assert_equal(File.read(file), 'ok')
          assert_empty(out)
          assert_match(/^Downloading .* from http.*$/, err)
        end
      end
    end

    private

    def with_dir(bundler_credential:)
      Dir.mktmpdir do |dir|
        File.write("#{dir}/Gemfile", 'source "https://rubygems.org"')

        if bundler_credential
          FileUtils.mkdir("#{dir}/.bundle")
          File.write("#{dir}/.bundle/config", "---\nBUNDLE_127__0__0__1: #{bundler_credential}\n")
        end

        Dir.chdir(dir) do
          Bundler.reset!
          yield(dir)
        end
      end
    end

    def with_server(returning_content:)
      server = TCPServer.new('127.0.0.1', 0)
      port_num = server.addr[1]

      @request = ''

      Thread.abort_on_exception = true
      thr = Thread.new do
        conn = server.accept
        until (line = conn.readline) == "\r\n"
          @request << line
        end

        conn.write(
          "HTTP/1.1 200 OK\r\n" \
          "Content-Length: #{returning_content.length}\r\n" \
          "Content-Type: text/plain\r\n" \
          "\r\n" \
          "#{returning_content}"
        )

        conn.close
      end

      yield(port_num)
    ensure
      server.close
      thr.join
    end
  end
end
