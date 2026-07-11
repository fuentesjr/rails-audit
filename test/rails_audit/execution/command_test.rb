# frozen_string_literal: true

require "rbconfig"
require "test_helper"

class ExecutionCommandTest < Minitest::Test
  RUBY = RbConfig.ruby

  def test_streams_source_stdout_to_target_stdin
    result = RailsAudit::Execution::Command.new.pipe(
      source_argv: [RUBY, "-e", '$stdout.write("fixture")'],
      target_argv: [RUBY, "-e", "$stdout.write($stdin.read.upcase)"],
      timeout: 5
    )

    assert result.success?
    assert_equal "FIXTURE", result.stdout
  end

  def test_source_failure_is_not_hidden_by_a_successful_target
    result = RailsAudit::Execution::Command.new.pipe(
      source_argv: [RUBY, "-e", '$stderr.write("tar failed"); exit 7'],
      target_argv: [RUBY, "-e", "$stdin.read"],
      timeout: 5
    )

    refute result.success?
    assert_equal 7, result.exit_code
    assert_includes result.stderr, "tar failed"
  end

  def test_broken_target_pipe_returns_a_command_failure
    result = RailsAudit::Execution::Command.new.pipe(
      source_argv: [RUBY, "-e", '$stdout.write("x" * 10_000_000)'],
      target_argv: [RUBY, "-e", "exit 9"],
      timeout: 5
    )

    refute result.success?
  end
end
