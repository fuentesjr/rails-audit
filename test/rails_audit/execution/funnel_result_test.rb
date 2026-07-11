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
      image_ref: "rails-audit/ruby:3.4"
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
      container_image_ref: "rails-audit/ruby:3.4"
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
      image_ref: "rails-audit/ruby:3.4"
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

  private

  def stage(name, status, duration, reason)
    RailsAudit::Execution::StageResult.new(name:, status:, duration:, reason:)
  end
end
