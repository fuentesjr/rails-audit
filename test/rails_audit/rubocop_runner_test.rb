# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "test_helper"

class RubocopRunnerTest < Minitest::Test
  Status = Data.define(:exitstatus)

  def test_runs_with_cli_owned_config_and_parses_tool_output
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "raw", "rubocop.json")
      observed = {}
      capture = lambda do |env, *argv, chdir:|
        observed[:env] = env
        observed[:argv] = argv
        observed[:chdir] = chdir
        FileUtils.cp(raw_fixture_path, argv.fetch(argv.index("--out") + 1))
        ["", "", Status.new(1)]
      end

      result = RailsAudit::Runners.rubocop(
        target: "/target/app",
        output_path: output_path,
        capture: capture
      )

      assert_equal [
        "bundle", "exec", "rubocop", ".",
        "--require", RailsAudit::Runners::RUBOCOP_COPS,
        "--config", RailsAudit::Runners::RUBOCOP_CONFIG,
        "--format", "json", "--out", output_path
      ], observed.fetch(:argv)
      assert_equal({ "BUNDLE_GEMFILE" => File.join(RailsAudit::Runners::ROOT, "Gemfile") },
                   observed.fetch(:env))
      assert_equal "/target/app", observed.fetch(:chdir)
      config = YAML.safe_load_file(RailsAudit::Runners::RUBOCOP_CONFIG)
      all_cops = config.fetch("AllCops")
      assert_equal "disable", all_cops.fetch("NewCops")
      assert_equal %w[**/db/schema.rb **/bin/**/* **/vendor/**/* **/node_modules/**/* **/tmp/**/*],
                   all_cops.fetch("Exclude")
      refute_includes all_cops.fetch("Exclude"), "**/db/migrate/**/*",
                       "migrations are real code and must never be excluded"
      assert_equal JSON.parse(File.read(raw_fixture_path)), result.fetch(:payload)
      assert_equal "rubocop", result.fetch(:name)
      assert_equal "1.88.2", result.fetch(:version)
      assert_equal 1, result.fetch(:exit_code)
      assert_equal 11_176, result.fetch(:raw_count)
      assert_equal output_path, result.fetch(:output_path)
    end
  end

  def test_accepts_the_no_offenses_exit_code
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")
      capture = lambda do |_env, *_argv, **_kwargs|
        FileUtils.cp(raw_fixture_path, output_path)
        ["", "", Status.new(0)]
      end

      result = RailsAudit::Runners.rubocop(
        target: "/target/app",
        output_path: output_path,
        capture: capture
      )

      assert_equal 0, result.fetch(:exit_code)
    end
  end

  def test_missing_plugin_crash_has_a_distinct_missing_output_failure
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")
      capture = lambda do |_env, *_argv, **_kwargs|
        ["", "cannot load such file -- rubocop-example", Status.new(2)]
      end

      error = assert_raises(RailsAudit::Runners::MissingOutputError) do
        RailsAudit::Runners.rubocop(
          target: "/target/app",
          output_path: output_path,
          capture: capture
        )
      end

      assert_includes error.message, "rubocop"
      assert_includes error.message, "2"
      assert_includes error.message, "missing or empty output"
      assert_includes error.message, output_path
      assert_includes error.message, "cannot load such file -- rubocop-example"
    end
  end

  def test_raises_for_an_unknown_exit_code_when_output_exists
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "rubocop.json")
      capture = lambda do |_env, *_argv, **_kwargs|
        FileUtils.cp(raw_fixture_path, output_path)
        ["", "rubocop crashed", Status.new(2)]
      end

      error = assert_raises(RailsAudit::Error) do
        RailsAudit::Runners.rubocop(
          target: "/target/app",
          output_path: output_path,
          capture: capture
        )
      end

      refute_kind_of RailsAudit::Runners::MissingOutputError, error
      assert_includes error.message, "rubocop"
      assert_includes error.message, "2"
      assert_includes error.message, "known: [0, 1]"
      assert_includes error.message, "rubocop crashed"
    end
  end

  private

  def raw_fixture_path
    File.expand_path("../fixtures/raw/rubocop.json", __dir__)
  end
end
