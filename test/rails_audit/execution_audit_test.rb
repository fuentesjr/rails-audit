# frozen_string_literal: true

require "json"
require "stringio"
require "test_helper"
require "tmpdir"

class ExecutionAuditTest < Minitest::Test
  STATIC_TARGET = File.expand_path("../fixtures/target_app", __dir__)

  class FakeHarness
    attr_reader :sources

    def initialize(result)
      @result = result
      @sources = []
    end

    def run(source:)
      @sources << source
      @result
    end
  end

  def test_cli_refuses_without_untrusted_code_acknowledgment_before_running_harness
    harness = FakeHarness.new(successful_result)
    stdout, stderr = StringIO.new, StringIO.new

    status = RailsAudit::CLI.new(stdout:, stderr:, execution_harness: harness).run(
      ["execution-audit", "/target/app"]
    )

    assert_equal 1, status
    assert_empty harness.sources
    assert_empty stdout.string
    assert_includes stderr.string, "Refusing to run untrusted target code"
    assert_includes stderr.string, "--i-understand-untrusted-code-runs"
  end

  def test_cli_with_acknowledgment_writes_separate_enveloped_artifact_and_report
    Dir.mktmpdir do |dir|
      harness = FakeHarness.new(successful_result)
      stdout, stderr = StringIO.new, StringIO.new
      output = File.join(dir, "custom-execution.json")
      report = File.join(dir, "custom-execution.md")
      static_findings = File.join(dir, "findings.json")
      static_report = File.join(dir, "RAILS_AUDIT_REPORT.md")
      File.write(static_findings, "static sentinel")
      File.write(static_report, "static report sentinel")

      status = RailsAudit::CLI.new(stdout:, stderr:, execution_harness: harness).run([
        "execution-audit", "/target/app", "--i-understand-untrusted-code-runs",
        "--output", output, "--report", report
      ])

      assert_equal 0, status, stderr.string
      assert_equal [File.expand_path("/target/app")], harness.sources
      assert_equal "static sentinel", File.read(static_findings)
      assert_equal "static report sentinel", File.read(static_report)

      document = JSON.parse(File.read(output))
      assert_equal "execution", document.fetch("tier")
      assert_equal false, document.fetch("pinned_by_us")
      assert_equal false, document.fetch("warranted_reproducible")
      assert_equal "sha256:abc123", document.fetch("container_image_digest")
      assert_equal "postgresql", document.fetch("db_adapter")
      assert_equal "ok", document.dig("funnel_stages", "boot", "status")
      assert_equal({
        "version" => "2.0.1", "status" => "findings", "exit_code" => 1,
        "timed_out" => false, "reason" => ""
      }, document.dig("tool_runs", "active_record_doctor"))
      assert_equal "users.account_id", document.dig("findings", 0, "context", "subject")

      rendered = File.read(report)
      assert rendered.start_with?("# Execution tier (not warranted reproducible)")
      assert_operator rendered.index("## Status"), :<, rendered.index("## Findings")
      assert_includes rendered, "`db/schema.rb:1`"
      assert_includes rendered, "**unindexed_foreign_keys**"
      assert_includes rendered, "add an index on users(account_id)"
      assert_includes rendered, "impact: medium"
      assert_includes rendered, "confidence: medium"
      assert_includes stdout.string, "1 execution findings"
    end
  end

  def test_failed_funnel_writes_status_and_reason_instead_of_clean_looking_artifact
    Dir.mktmpdir do |dir|
      output = File.join(dir, "execution-findings.json")
      report = File.join(dir, "EXECUTION_AUDIT_REPORT.md")

      status = RailsAudit::ExecutionAudit.run(
        target: "/target/app", output_path: output, report_path: report,
        harness: FakeHarness.new(failed_result), stdout: StringIO.new
      )

      assert_equal 1, status
      document = JSON.parse(File.read(output))
      assert_equal "install_failed", document.fetch("outcome")
      assert_empty document.fetch("findings")
      assert_equal "native extension failed",
                   document.dig("funnel_stages", "bundle_install", "reason")
      assert_equal "skipped", document.dig("tool_runs", "active_record_doctor", "status")
      assert_includes document.dig("tool_runs", "active_record_doctor", "reason"), "install_failed"

      rendered = File.read(report)
      assert_includes rendered, "**Overall status: install_failed**"
      assert_includes rendered, "native extension failed"
      assert_operator rendered.index("install_failed"), :<, rendered.index("## Findings")
      assert_includes rendered, "No findings because the execution funnel did not complete."
    end
  end

  def test_failed_tool_changes_document_outcome_and_preserves_diagnostic_reason
    result = successful_result
    failed = RailsAudit::Execution::FunnelResult.new(
      stages: result.stages, versions: result.versions, image_ref: result.image_ref,
      image_digest: result.image_digest,
      tool_runs: [tool_run(:failed, exit_code: 2, reason: "unexpected output\ntool crashed")]
    )

    Dir.mktmpdir do |dir|
      output = File.join(dir, "execution-findings.json")
      report = File.join(dir, "EXECUTION_AUDIT_REPORT.md")
      stdout = StringIO.new
      status = RailsAudit::ExecutionAudit.run(
        target: "/target/app", output_path: output, report_path: report,
        harness: FakeHarness.new(failed), stdout:
      )

      assert_equal 1, status
      assert_includes stdout.string, "outcome tool_failed"
      assert_equal "tool_failed", JSON.parse(File.read(output)).fetch("outcome")
      rendered = File.read(report)
      assert_includes rendered, "**Overall status: tool_failed**"
      assert_includes rendered, "unexpected output<br>tool crashed"
      assert_includes rendered, "No findings because an execution tool failed."
    end
  end

  def test_rejects_colliding_or_static_reserved_paths_before_running_harness
    Dir.mktmpdir do |dir|
      [
        [File.join(dir, "same"), File.join(dir, "same")],
        [File.join(dir, "findings.json"), File.join(dir, "execution.md")],
        [File.join(dir, "execution.json"), File.join(dir, "RAILS_AUDIT_REPORT.md")]
      ].each do |output, report|
        harness = FakeHarness.new(successful_result)

        assert_raises(RailsAudit::Error) do
          RailsAudit::ExecutionAudit.run(
            target: "/target/app", output_path: output, report_path: report,
            harness:, stdout: StringIO.new
          )
        end
        assert_empty harness.sources
      end
    end
  end

  def test_subsequent_static_audit_does_not_clobber_execution_artifacts
    Dir.mktmpdir do |dir|
      execution_path = File.join(dir, "execution-findings.json")
      execution_report_path = File.join(dir, "EXECUTION_AUDIT_REPORT.md")
      cli = RailsAudit::CLI.new(
        stdout: StringIO.new, stderr: StringIO.new,
        execution_harness: FakeHarness.new(successful_result)
      )
      assert_equal 0, cli.run([
        "execution-audit", "/target/app", "--i-understand-untrusted-code-runs",
        "--output", execution_path, "--report", execution_report_path
      ])
      artifact_before = File.binread(execution_path)
      report_before = File.binread(execution_report_path)

      assert_equal 0, cli.run(["audit", STATIC_TARGET, "--output-dir", dir])

      assert_path_exists File.join(dir, "findings.json")
      assert_path_exists File.join(dir, "RAILS_AUDIT_REPORT.md")
      assert_equal artifact_before, File.binread(execution_path)
      assert_equal report_before, File.binread(execution_report_path)
    end
  end

  private

  def successful_result
    RailsAudit::Execution::FunnelResult.new(
      stages: RailsAudit::Execution::STAGE_NAMES.map { |name| stage(name, :ok, "") },
      versions: {
        ruby: "3.4.5", rails: "7.2.3.1", adapter: "postgresql",
        active_record_doctor: "2.0.1"
      },
      image_ref: "rails-audit-execution-ruby:3.4.5",
      image_digest: "sha256:abc123",
      findings: [finding],
      tool_runs: [tool_run(:findings, exit_code: 1)]
    )
  end

  def failed_result
    RailsAudit::Execution::FunnelResult.new(
      stages: [
        stage(:clone_or_copy, :ok, ""),
        stage(:bundle_install, :install_failed, "native extension failed"),
        stage(:schema_load, :skipped, "bundle_install did not complete"),
        stage(:boot, :skipped, "bundle_install did not complete")
      ],
      versions: { ruby: "3.4.5", rails: nil, adapter: "postgresql" },
      image_ref: "rails-audit-execution-ruby:3.4.5",
      image_digest: "sha256:abc123",
      tool_runs: [tool_run(:skipped, reason: "install_failed prevented tool execution")]
    )
  end

  def stage(name, status, reason)
    RailsAudit::Execution::StageResult.new(name:, status:, duration: 0.1, reason:)
  end

  def tool_run(status, exit_code: nil, reason: "")
    RailsAudit::Execution::ToolRun.new(
      name: :active_record_doctor, version: "2.0.1", status:, exit_code:,
      timed_out: false, reason:
    )
  end

  def finding
    RailsAudit::Finding.new(
      native_fingerprint: nil, tool: "active_record_doctor", rule: "unindexed_foreign_keys",
      category: "performance", impact: "medium", confidence: "medium",
      message: "add an index on users(account_id)",
      location: { file: "db/schema.rb", start_line: 1, end_line: 1, column: nil, lines: nil },
      context: { subject: "users.account_id" }, discriminator: "users.account_id"
    )
  end
end
