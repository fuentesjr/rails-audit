# frozen_string_literal: true

require "json"
require "tmpdir"
require "test_helper"

class ReekRunnerTest < Minitest::Test
  Status = Data.define(:exitstatus)

  def test_captures_stdout_to_disk_and_parses_tool_output
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "raw", "reek.json")
      observed = {}
      capture = lambda do |*argv, chdir:|
        observed[:argv] = argv
        observed[:chdir] = chdir
        [File.read(raw_fixture_path), "", Status.new(2)]
      end

      result = RailsAudit::Runners.reek(
        target: "/target/app",
        output_path: output_path,
        capture: capture
      )

      assert_equal [
        "bundle", "exec", "reek", "/target/app", "--format", "json"
      ], observed.fetch(:argv)
      assert_equal RailsAudit::Runners::ROOT, observed.fetch(:chdir)
      assert_equal File.read(raw_fixture_path), File.read(output_path)
      assert_equal JSON.parse(File.read(raw_fixture_path)), result.fetch(:payload)
      assert_equal "reek", result.fetch(:name)
      assert_equal "6.5.0", result.fetch(:version)
      assert_equal 2, result.fetch(:exit_code)
      assert_equal 1_700, result.fetch(:raw_count)
      assert_equal output_path, result.fetch(:output_path)
    end
  end

  def test_accepts_the_no_smells_exit_code
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "reek.json")
      capture = lambda do |*argv, chdir:|
        [File.read(raw_fixture_path), "", Status.new(0)]
      end

      result = RailsAudit::Runners.reek(
        target: "/target/app",
        output_path: output_path,
        capture: capture
      )

      assert_equal 0, result.fetch(:exit_code)
    end
  end

  def test_writes_partial_stdout_before_rejecting_an_unknown_exit_code
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "reek.json")
      capture = lambda do |*argv, chdir:|
        ["partial output", "reek failed", Status.new(1)]
      end

      error = assert_raises(RailsAudit::Error) do
        RailsAudit::Runners.reek(
          target: "/target/app",
          output_path: output_path,
          capture: capture
        )
      end

      assert_equal "partial output", File.read(output_path)
      assert_includes error.message, "reek"
      assert_includes error.message, "1"
      assert_includes error.message, "known: [0, 2]"
      assert_includes error.message, "reek failed"
    end
  end

  private

  def raw_fixture_path
    File.expand_path("../fixtures/raw/reek.json", __dir__)
  end
end
