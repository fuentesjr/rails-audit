# frozen_string_literal: true

require "test_helper"

class FunnelResultTest < Minitest::Test
  def test_serializes_successful_stages_and_resolved_environment
    result = RailsAudit::Execution::FunnelResult.new(
      stages: [
        stage(:clone_or_copy, :ok, 0.12, "copied target"),
        stage(:bundle_install, :ok, 1.23, "Bundle complete"),
        stage(:schema_load, :ok, 0.45, "Loaded schema"),
        stage(:boot, :ok, 0.67, "eager load complete")
      ],
      versions: { ruby: "3.4.5", rails: "7.2.3.1", adapter: "postgresql" },
      image_ref: "rails-audit/ruby:3.4",
      image_digest: "sha256:abc123",
      findings: [finding],
      tool_runs: [tool_run(:findings, version: "2.0.1", exit_code: 1)]
    )

    assert_equal :ok, result.outcome
    assert_equal({
      outcome: "ok",
      stages: {
        clone_or_copy: { status: "ok", duration: 0.12, reason: "copied target" },
        bundle_install: { status: "ok", duration: 1.23, reason: "Bundle complete" },
        schema_load: { status: "ok", duration: 0.45, reason: "Loaded schema" },
        boot: { status: "ok", duration: 0.67, reason: "eager load complete" }
      },
      resolved_versions: { ruby: "3.4.5", rails: "7.2.3.1", adapter: "postgresql" },
      container_image_ref: "rails-audit/ruby:3.4",
      container_image_digest: "sha256:abc123",
      tool_runs: {
        active_record_doctor: {
          version: "2.0.1", status: "findings", exit_code: 1,
          timed_out: false, reason: ""
        }
      },
      findings: [finding.to_h]
    }, result.to_h)
  end

  def test_failure_becomes_the_outcome_and_requires_later_stages_to_be_skipped
    result = RailsAudit::Execution::FunnelResult.new(
      stages: [
        stage(:clone_or_copy, :ok, 0.1, ""),
        stage(:bundle_install, :install_failed, 0.2, "native extension failed"),
        stage(:schema_load, :skipped, 0.0, "bundle_install did not complete"),
        stage(:boot, :skipped, 0.0, "bundle_install did not complete")
      ],
      versions: { ruby: "3.4", rails: nil, adapter: "postgresql" },
      image_ref: "rails-audit/ruby:3.4",
      tool_runs: [tool_run(:skipped, reason: "install_failed prevented tool execution")]
    )

    assert_equal :install_failed, result.outcome
    assert_equal "install_failed", result.to_h.fetch(:outcome)
  end

  def test_rejects_an_unknown_stage_status
    error = assert_raises(ArgumentError) do
      RailsAudit::Execution::StageResult.new(
        name: :boot, status: :clean, duration: 0.1, reason: ""
      )
    end

    assert_includes error.message, "clean"
  end

  def test_failure_cannot_carry_findings
    error = assert_raises(ArgumentError) do
      RailsAudit::Execution::FunnelResult.new(
        stages: [
          stage(:clone_or_copy, :ok, 0.1, ""),
          stage(:bundle_install, :install_failed, 0.2, "failed"),
          stage(:schema_load, :skipped, 0.0, "skipped"),
          stage(:boot, :skipped, 0.0, "skipped")
        ],
        versions: {}, image_ref: nil, findings: [finding],
        tool_runs: [tool_run(:skipped, reason: "install_failed prevented tool execution")]
      )
    end

    assert_includes error.message, "findings"
  end

  def test_tool_failure_is_the_authoritative_overall_outcome
    result = RailsAudit::Execution::FunnelResult.new(
      stages: RailsAudit::Execution::STAGE_NAMES.map { |name| stage(name, :ok, 0.1, "") },
      versions: {}, image_ref: "image",
      tool_runs: [tool_run(:failed, exit_code: 2, reason: "tool crashed")]
    )

    assert_equal :ok, result.funnel_outcome
    assert_equal :tool_failed, result.outcome
    assert_equal "tool_failed", result.to_h.fetch(:outcome)
  end

  def test_tool_run_rejects_unknown_status_and_requires_a_reason
    error = assert_raises(ArgumentError) { tool_run(:unknown, reason: "bad status") }
    assert_includes error.message, "unknown tool status"

    assert_raises(ArgumentError) do
      RailsAudit::Execution::ToolRun.new(
        name: :active_record_doctor, version: "2.0.1", status: :clean,
        exit_code: 0, timed_out: false
      )
    end
  end

  def test_funnel_result_rejects_raw_or_missing_tool_runs
    stages = RailsAudit::Execution::STAGE_NAMES.map { |name| stage(name, :ok, 0.1, "") }

    assert_raises(ArgumentError) do
      RailsAudit::Execution::FunnelResult.new(
        stages:, versions: {}, image_ref: "image",
        tool_runs: [{ status: "clean", reason: "" }]
      )
    end
    assert_raises(ArgumentError) do
      RailsAudit::Execution::FunnelResult.new(
        stages:, versions: {}, image_ref: "image", tool_runs: []
      )
    end
  end

  def test_funnel_result_rejects_tool_status_inconsistent_with_funnel
    successful_stages = RailsAudit::Execution::STAGE_NAMES.map do |name|
      stage(name, :ok, 0.1, "")
    end
    failed_stages = [
      stage(:clone_or_copy, :ok, 0.1, ""),
      stage(:bundle_install, :install_failed, 0.1, "failed"),
      stage(:schema_load, :skipped, 0.0, "skipped"),
      stage(:boot, :skipped, 0.0, "skipped")
    ]

    assert_raises(ArgumentError) do
      RailsAudit::Execution::FunnelResult.new(
        stages: successful_stages, versions: {}, image_ref: "image",
        tool_runs: [tool_run(:skipped, reason: "did not run")]
      )
    end
    assert_raises(ArgumentError) do
      RailsAudit::Execution::FunnelResult.new(
        stages: failed_stages, versions: {}, image_ref: "image",
        tool_runs: [tool_run(:clean)]
      )
    end
  end

  private

  def stage(name, status, duration, reason)
    RailsAudit::Execution::StageResult.new(name:, status:, duration:, reason:)
  end

  def tool_run(status, version: nil, exit_code: nil, timed_out: false, reason: "")
    RailsAudit::Execution::ToolRun.new(
      name: :active_record_doctor, version:, status:, exit_code:, timed_out:, reason:
    )
  end

  def finding
    RailsAudit::Finding.new(
      native_fingerprint: nil,
      tool: "active_record_doctor",
      rule: "unindexed_foreign_keys",
      category: "performance",
      impact: "medium",
      confidence: "medium",
      message: "add an index on users(account_id)",
      location: { file: "db/schema.rb", start_line: 1, end_line: 1, column: nil, lines: nil },
      context: { subject: "users.account_id" },
      discriminator: "users.account_id"
    )
  end
end
