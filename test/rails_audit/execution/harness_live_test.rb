# frozen_string_literal: true

require "test_helper"

class ExecutionHarnessLiveTest < Minitest::Test
  TARGET = File.expand_path("../../fixtures/execution/synthetic_app", __dir__)

  def test_full_funnel_against_synthetic_app
    skip "Docker daemon is unavailable" unless docker_available?

    result = RailsAudit::Execution::Harness.new.run(source: TARGET)

    assert_equal :ok, result.outcome, result.to_h.inspect
    assert_equal %i[ok ok ok ok], result.stages.map(&:status), result.to_h.inspect
    assert_equal "postgresql", result.versions.fetch(:adapter)
    assert_equal "3.4.5", result.versions.fetch(:ruby)
  end

  private

  def docker_available?
    system("docker", "info", out: File::NULL, err: File::NULL)
  end
end
