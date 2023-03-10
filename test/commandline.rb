# frozen_string_literal: true

require 'minitest/autorun'
require 'bundix/commandline'

class CommandLineTest < Minitest::Test
  def setup
    @cli = Bundix::CommandLine.new
    @cli.options = {
      project: 'test-project',
      ruby: 'test-ruby',
      gemfile: 'test-gemfile',
      lockfile: 'test-lockfile',
      gemset: 'test-gemset'
    }
  end
end
