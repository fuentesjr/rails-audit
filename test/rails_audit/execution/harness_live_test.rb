# frozen_string_literal: true

require "test_helper"

class ExecutionHarnessLiveTest < Minitest::Test
  TARGET = File.expand_path("../../fixtures/execution/synthetic_app", __dir__)

  def test_full_funnel_against_synthetic_app
    skip "Docker daemon is unavailable" unless docker_available?
    assert File.exist?(File.join(TARGET, ".active_record_doctor.rb")),
           "fixture must try to suppress the unindexed foreign-key detector"

    result = RailsAudit::Execution::Harness.new.run(source: TARGET)

    assert_equal :ok, result.outcome, result.to_h.inspect
    assert_equal %i[ok ok ok ok], result.stages.map(&:status), result.to_h.inspect
    assert_equal "postgresql", result.versions.fetch(:adapter)
    assert_equal "3.4.5", result.versions.fetch(:ruby)
    assert_equal "2.0.1", result.versions.fetch(:active_record_doctor)
    assert_equal 1, result.tool_runs.fetch(:active_record_doctor).exit_code

    unindexed = result.findings.find do |finding|
      finding.rule == "unindexed_foreign_keys" && finding.context.fetch(:subject) == "users.account_id"
    end
    refute_nil unindexed, result.to_h.inspect

    unique = result.findings.find do |finding|
      finding.rule == "missing_unique_indexes" && finding.context.fetch(:subject) == "users.email"
    end
    refute_nil unique, result.to_h.inspect
  end

  private

  def docker_available?
    system("docker", "info", out: File::NULL, err: File::NULL)
  end
end
