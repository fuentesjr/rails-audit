# frozen_string_literal: true

require "json"
require "tmpdir"
require "stringio"
require "test_helper"

class CLITest < Minitest::Test
  TARGET_APP = File.expand_path("../fixtures/target_app", __dir__)
  SCHEMA_APP = File.expand_path("../fixtures/schema_app", __dir__)
  SCHEMA_MISSING_WARNING = RailsAudit::CLI::SCHEMA_MISSING_WARNING

  def test_default_max_findings
    assert_equal 500_000, RailsAudit::CLI::DEFAULT_MAX_FINDINGS
  end

  def test_missing_subcommand_prints_usage_and_returns_non_zero
    stdout, stderr = StringIO.new, StringIO.new
    status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run([])

    refute_equal 0, status
    assert_includes stderr.string, "Usage: rails-audit audit TARGET"
    assert_empty stdout.string
  end

  def test_unknown_subcommand_prints_usage_and_returns_non_zero
    stdout, stderr = StringIO.new, StringIO.new
    status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(["bogus"])

    refute_equal 0, status
    assert_includes stderr.string, "Usage: rails-audit audit TARGET"
  end

  def test_audit_without_a_target_prints_usage_and_returns_non_zero
    stdout, stderr = StringIO.new, StringIO.new
    status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(["audit"])

    refute_equal 0, status
    assert_includes stderr.string, "Usage: rails-audit audit TARGET"
  end

  def test_audit_end_to_end_against_real_tools_and_the_fixture_target_app
    Dir.mktmpdir do |output_dir|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
        ["audit", TARGET_APP, "--output-dir", output_dir]
      )

      assert_equal 0, status, "expected success, stderr: #{stderr.string}"

      findings_path = File.join(output_dir, "findings.json")
      report_path = File.join(output_dir, "RAILS_AUDIT_REPORT.md")
      assert_path_exists findings_path
      assert_path_exists report_path

      document = JSON.parse(File.read(findings_path))
      findings = document.fetch("findings")
      refute_empty findings

      files = findings.map { |finding| finding.dig("location", "file") }
      refute_empty(files.select { |file| !file.start_with?("/") })
      assert_includes files, "app/controllers/users_controller.rb"
      assert files.none? { |file| file.start_with?("/") },
             "expected all finding paths to be target-root-relative, got: #{files.uniq}"

      report = File.read(report_path)
      assert_includes report, "# rails-audit report"
      assert_includes report, "## Security"
    end
  end

  def test_audit_fails_without_writing_outputs_when_findings_exceed_the_cap
    Dir.mktmpdir do |output_dir|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
        ["audit", TARGET_APP, "--output-dir", output_dir, "--max-findings", "1"]
      )

      refute_equal 0, status
      refute_path_exists File.join(output_dir, "findings.json")
      refute_path_exists File.join(output_dir, "RAILS_AUDIT_REPORT.md")
      assert_includes stderr.string, "1"
      assert_includes stderr.string, "--max-findings"
    end
  end

  def test_audit_writes_outputs_when_findings_are_under_the_cap
    Dir.mktmpdir do |output_dir|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
        ["audit", TARGET_APP, "--output-dir", output_dir, "--max-findings", "1000"]
      )

      assert_equal 0, status, "expected success, stderr: #{stderr.string}"
      assert_path_exists File.join(output_dir, "findings.json")
    end
  end

  def test_audit_rejects_invalid_max_findings_values_as_usage_errors
    ["0", "not-an-integer"].each do |max_findings|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
        ["audit", TARGET_APP, "--max-findings", max_findings]
      )

      refute_equal 0, status
      assert_includes stderr.string, "Usage: rails-audit audit TARGET"
      assert_empty stdout.string
    end
  end

  def test_audit_against_a_target_without_schema_rb_surfaces_a_warning
    Dir.mktmpdir do |output_dir|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
        ["audit", TARGET_APP, "--output-dir", output_dir]
      )

      assert_equal 0, status, "expected success, stderr: #{stderr.string}"

      document = JSON.parse(File.read(File.join(output_dir, "findings.json")))
      assert_equal [SCHEMA_MISSING_WARNING], document.fetch("warnings")
      assert_includes SCHEMA_MISSING_WARNING, "Schema/*"

      report = File.read(File.join(output_dir, "RAILS_AUDIT_REPORT.md"))
      assert_includes report, "## Warnings\n- #{SCHEMA_MISSING_WARNING}"
    end
  end

  def test_audit_against_a_target_with_schema_rb_has_no_warning
    Dir.mktmpdir do |output_dir|
      stdout, stderr = StringIO.new, StringIO.new
      status = with_environment("XDG_CACHE_HOME" => File.join(output_dir, "cache")) do
        RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(
          ["audit", SCHEMA_APP, "--output-dir", output_dir]
        )
      end

      assert_equal 0, status, "expected success, stderr: #{stderr.string}"

      document = JSON.parse(File.read(File.join(output_dir, "findings.json")))
      assert_empty document.fetch("warnings")
      schema_tool = document.fetch("tools").find { |tool| tool.fetch("name") == "schema" }
      schema_findings = document.fetch("findings").select do |finding|
        finding.fetch("tool") == "schema"
      end

      refute_nil schema_tool
      assert_equal RailsAudit::VERSION, schema_tool.fetch("version")
      assert_equal schema_findings.size, schema_tool.fetch("raw_count")
      assert_equal RailsAudit::Mappings::SCHEMA_RULES.keys.sort,
                   schema_findings.map { |finding| finding.fetch("rule") }.uniq.sort
      assert_equal schema_findings.size, schema_findings.map { |finding| finding.fetch("id") }.uniq.size

      report = File.read(File.join(output_dir, "RAILS_AUDIT_REPORT.md"))
      refute_includes report, "## Warnings"
    end
  end

  def test_annotate_missing_findings_file_and_unknown_arguments_return_usage_errors
    [
      ["annotate"],
      ["annotate", "findings.json", "extra"],
      ["annotate", "findings.json", "--bogus"]
    ].each do |argv|
      stdout, stderr = StringIO.new, StringIO.new
      status = RailsAudit::CLI.new(stdout: stdout, stderr: stderr).run(argv)

      refute_equal 0, status
      assert_includes stderr.string, "rails-audit annotate FINDINGS_JSON"
      assert_empty stdout.string
    end
  end

  private

  def with_environment(values)
    original = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
