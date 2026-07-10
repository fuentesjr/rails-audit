# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "test_helper"

class BrakemanRunnerTest < Minitest::Test
  Status = Data.define(:exitstatus)

  def test_runs_with_cli_owned_empty_ignore_and_parses_tool_output
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "raw", "brakeman.json")
      observed = {}
      capture = lambda do |*argv, chdir:|
        observed[:argv] = argv
        observed[:chdir] = chdir
        observed[:ignore_path] = argv.fetch(argv.index("-i") + 1)
        observed[:ignore_contents] = File.read(observed[:ignore_path])
        FileUtils.cp(raw_fixture_path, argv.fetch(argv.index("-o") + 1))
        ["", "", Status.new(3)]
      end

      result = RailsAudit::Runners.brakeman(
        target: "/target/app",
        output_path: output_path,
        capture: capture
      )

      assert_equal [
        "bundle", "exec", "brakeman", "-p", "/target/app", "-f", "json",
        "-o", output_path, "-i", observed.fetch(:ignore_path)
      ], observed.fetch(:argv)
      assert_equal RailsAudit::Runners::ROOT, observed.fetch(:chdir)
      assert_equal '{"ignored_warnings":[],"updated":null}', observed.fetch(:ignore_contents)
      assert_equal JSON.parse(File.read(raw_fixture_path)), result.fetch(:payload)
      assert_equal "brakeman", result.fetch(:name)
      assert_equal "8.0.5", result.fetch(:version)
      assert_equal 3, result.fetch(:exit_code)
      assert_equal 27, result.fetch(:raw_count)
      assert_equal output_path, result.fetch(:output_path)
    end
  end

  def test_can_respect_the_target_ignore_file
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "brakeman.json")
      argv = nil
      capture = lambda do |*captured_argv, chdir:|
        argv = captured_argv
        FileUtils.cp(raw_fixture_path, output_path)
        ["", "", Status.new(0)]
      end

      result = RailsAudit::Runners.brakeman(
        target: "/target/app",
        output_path: output_path,
        respect_target_config: true,
        capture: capture
      )

      refute_includes argv, "-i"
      assert_equal 0, result.fetch(:exit_code)
    end
  end

  def test_raises_for_an_unknown_exit_code_with_stderr
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "brakeman.json")
      capture = lambda do |*argv, chdir:|
        FileUtils.cp(raw_fixture_path, output_path)
        ["", "brakeman crashed", Status.new(7)]
      end

      error = assert_raises(RailsAudit::Error) do
        RailsAudit::Runners.brakeman(
          target: "/target/app",
          output_path: output_path,
          capture: capture
        )
      end

      assert_includes error.message, "brakeman"
      assert_includes error.message, "7"
      assert_includes error.message, "known: [0, 3]"
      assert_includes error.message, "brakeman crashed"
    end
  end

  private

  def raw_fixture_path
    File.expand_path("../fixtures/raw/brakeman.json", __dir__)
  end
end
