# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ExecutionHarnessTest < Minitest::Test
  class FakeDocker
    attr_reader :commands, :network

    def initialize(fail_build: false, fail_bundle: false, fail_postgres: false,
                   file_check_error: false, malformed_tool: false,
                   tool_exit_code: 0, tool_timed_out: false)
      @commands = []
      @fail_build = fail_build
      @fail_bundle = fail_bundle
      @fail_postgres = fail_postgres
      @file_check_error = file_check_error
      @malformed_tool = malformed_tool
      @tool_exit_code = tool_exit_code
      @tool_timed_out = tool_timed_out
    end

    def capture(*argv, timeout:, env: {})
      @commands << argv
      @last_timeout = timeout
      @last_env = env
      @network = argv.last if argv[0, 3] == ["docker", "network", "create"]
      return result(stdout: "29.0.0") if argv[0, 2] == ["docker", "version"]
      if argv.include?("alpine/git")
        return result(stdout: "RAILS_AUDIT_RUBY\n3.4.5\nRAILS_AUDIT_GEMFILE\ngem \"pg\"\nRAILS_AUDIT_DATABASE\n")
      end
      return result(stderr: "image not found", exit_code: 1) if @fail_build && argv[0, 2] == ["docker", "build"]
      return result(stdout: "sha256:fake-image-id\n") if argv[0, 3] == ["docker", "image", "inspect"]
      return result(stdout: "3.4.5\n7.2.3.1\n2.0.1\n") if argv.any? { |arg| arg.include?("Gem.loaded_specs") }
      if argv.include?(RailsAudit::Execution::Harness::ACTIVE_RECORD_DOCTOR_RUNNER)
        return result(stderr: "tool crashed", exit_code: 2) if @malformed_tool

        return result(
          stdout: clean_active_record_doctor_output,
          exit_code: @tool_exit_code,
          timed_out: @tool_timed_out
        )
      end
      return result(stdout: "#{network}\n") if argv[0, 2] == ["docker", "inspect"]
      if @file_check_error && argv.each_cons(2).any? { |pair| pair == ["test", "-f"] }
        return result(stderr: "docker exec failed", exit_code: 125)
      end
      return result(stderr: "native extension failed", exit_code: 7) if bundle_install?(argv)
      if @fail_postgres && argv.include?(RailsAudit::Execution::Harness::POSTGRES_IMAGE)
        return result(stderr: "database container failed", exit_code: 8)
      end

      result
    end

    def pipe(source_argv:, target_argv:, timeout:, source_env: {})
      @last_pipe = [source_argv, target_argv, timeout, source_env]
      result
    end

    private

    def bundle_install?(argv)
      @fail_bundle && argv.each_cons(2).any? { |pair| pair == ["bundle", "install"] }
    end

    def clean_active_record_doctor_output
      lines = [RailsAudit::Execution::ActiveRecordDoctorParser::BEGIN_REPORT]
      RailsAudit::Execution::ActiveRecordDoctorParser::DETECTORS.each do |detector|
        lines << "RAILS_AUDIT_DETECTOR_BEGIN #{detector}"
        lines << "RAILS_AUDIT_DETECTOR_END #{detector} clean"
      end
      lines << RailsAudit::Execution::ActiveRecordDoctorParser::END_REPORT
      lines.join("\n") << "\n"
    end

    def result(stdout: "", stderr: "", exit_code: 0, timed_out: false)
      RailsAudit::Execution::CommandResult.new(
        stdout:, stderr:, exit_code:, timed_out:
      )
    end
  end

  def test_docker_unavailability_fails_loud_with_actionable_message
    command = Object.new
    command.define_singleton_method(:capture) do |*|
      RailsAudit::Execution::CommandResult.new(
        stdout: "", stderr: "Cannot connect to daemon", exit_code: 1, timed_out: false
      )
    end

    error = assert_raises(RailsAudit::Execution::DockerUnavailableError) do
      RailsAudit::Execution::Harness.new(command:).run(source: "/target/app")
    end

    assert_includes error.message, "Docker is required"
    assert_includes error.message, "docker info"
    assert_includes error.message, "Cannot connect to daemon"
  end

  def test_install_failure_is_reported_and_stops_the_funnel
    with_target('gem "pg"') do |target|
      result = RailsAudit::Execution::Harness.new(
        command: FakeDocker.new(fail_bundle: true)
      ).run(source: target)

      assert_equal :install_failed, result.outcome
      assert_equal %i[ok install_failed skipped skipped], result.stages.map(&:status)
      assert_includes result.stages.fetch(1).reason, "native extension failed"
    end
  end

  def test_bad_target_ruby_pin_returns_a_structured_result
    with_target('gem "pg"', ruby: "99.9") do |target|
      result = RailsAudit::Execution::Harness.new(
        command: FakeDocker.new(fail_build: true)
      ).run(source: target)

      assert_equal :clone_failed, result.outcome
      assert_equal %i[clone_failed skipped skipped skipped], result.stages.map(&:status)
      assert_includes result.stages.first.reason, "image not found"
    end
  end

  def test_mysql_returns_structured_unsupported_adapter_outcome
    with_target('gem "mysql2"') do |target|
      result = RailsAudit::Execution::Harness.new(command: FakeDocker.new).run(source: target)

      assert_equal :db_adapter_unsupported, result.outcome
      assert_equal %i[ok ok db_adapter_unsupported skipped], result.stages.map(&:status)
      assert_equal "mysql", result.versions.fetch(:adapter)
    end
  end

  def test_database_provisioning_failure_is_a_structured_schema_failure
    with_target('gem "pg"') do |target|
      result = RailsAudit::Execution::Harness.new(
        command: FakeDocker.new(fail_postgres: true)
      ).run(source: target)

      assert_equal :schema_failed, result.outcome
      assert_equal %i[ok ok schema_failed skipped], result.stages.map(&:status)
      assert_includes result.stages.fetch(2).reason, "database container failed"
    end
  end

  def test_schema_file_check_infrastructure_failure_is_not_treated_as_absence
    with_target('gem "pg"') do |target|
      result = RailsAudit::Execution::Harness.new(
        command: FakeDocker.new(file_check_error: true)
      ).run(source: target)

      assert_equal :schema_failed, result.outcome
      assert_includes result.stages.fetch(2).reason, "docker exec failed"
    end
  end

  def test_git_probe_is_named_tracked_and_clone_urls_follow_end_of_options
    command = FakeDocker.new
    result = RailsAudit::Execution::Harness.new(command:).run(
      source: "--upload-pack=malicious@host:repo"
    )

    assert_equal :ok, result.outcome
    probe = command.commands.find { |argv| argv.include?("alpine/git") }
    assert_match(/rails-audit-probe-/, probe.fetch(probe.index("--name") + 1))
    assert_includes probe.last, 'git clone --depth 1 -- "$TARGET_URL" /tmp/repo'

    clone = command.commands.find { |argv| argv.each_cons(4).any? { |args| args == ["git", "clone", "--depth", "1"] } }
    assert_equal ["--", "--upload-pack=malicious@host:repo", RailsAudit::Execution::Harness::APP_PATH], clone.last(3)
    assert(command.commands.any? do |argv|
      argv[0, 3] == ["docker", "rm", "--force"] && argv.last.match?(/rails-audit-probe-/)
    end)
  end

  def test_git_source_probe_script_preserves_shell_escapes_and_markers
    script = RailsAudit::Execution::Harness.new.send(:git_source_probe_script)

    assert_includes script, "find /tmp/repo/config -type f -exec cat {} \\;"
    assert_includes script, "printf 'RAILS_AUDIT_RUBY\\n'"
    assert_includes script, "printf '\\nRAILS_AUDIT_GEMFILE\\n'"
    assert_includes script, "printf '\\nRAILS_AUDIT_DATABASE\\n'"
  end

  def test_analysis_argv_contains_only_the_tier_owned_read_only_runner
    command = FakeDocker.new
    with_target('gem "pg"') do |target|
      result = RailsAudit::Execution::Harness.new(command:).run(source: target)

      assert_equal :ok, result.outcome
      analysis = command.commands.find do |argv|
        argv.include?(RailsAudit::Execution::Harness::ACTIVE_RECORD_DOCTOR_RUNNER)
      end
      assert_equal [
        "bundle", "exec", "ruby", RailsAudit::Execution::Harness::ACTIVE_RECORD_DOCTOR_RUNNER
      ], analysis.last(4)
      refute(analysis.any? { |argument| argument.match?(/(?:fix|generate|migration)/i) })
      assert_equal "2.0.1", result.tool_runs.fetch(:active_record_doctor).version
      assert_equal :clean, result.tool_runs.fetch(:active_record_doctor).status
      assert_equal "sha256:fake-image-id", result.image_digest
      assert_empty result.findings
    end
  end

  def test_tool_failure_is_structured_and_cannot_look_clean
    with_target('gem "pg"') do |target|
      result = RailsAudit::Execution::Harness.new(
        command: FakeDocker.new(malformed_tool: true)
      ).run(source: target)

      tool = result.tool_runs.fetch(:active_record_doctor)
      assert_equal :tool_failed, result.outcome
      assert_equal :ok, result.funnel_outcome
      assert_equal :failed, tool.status
      assert_equal 2, tool.exit_code
      assert_includes tool.reason, "tool crashed"
      assert_empty result.findings
    end
  end

  def test_parseable_clean_output_with_failed_process_status_cannot_look_clean
    [
      FakeDocker.new(tool_exit_code: 2),
      FakeDocker.new(tool_exit_code: nil, tool_timed_out: true)
    ].each do |command|
      with_target('gem "pg"') do |target|
        result = RailsAudit::Execution::Harness.new(command:).run(source: target)
        tool = result.tool_runs.fetch(:active_record_doctor)

        assert_equal :tool_failed, result.outcome
        assert_equal :failed, tool.status
        refute_empty tool.reason
        assert_empty result.findings
      end
    end
  end

  private

  def with_target(adapter_gem, ruby: "3.4.5")
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), "ruby \"#{ruby}\"\n#{adapter_gem}\n")
      yield dir
    end
  end
end
