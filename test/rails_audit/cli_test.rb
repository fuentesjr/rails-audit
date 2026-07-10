# frozen_string_literal: true

require "json"
require "tmpdir"
require "stringio"
require "test_helper"

class CLITest < Minitest::Test
  TARGET_APP = File.expand_path("../fixtures/target_app", __dir__)

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
      refute_empty files.select { |file| !file.start_with?("/") }
      assert_includes files, "app/controllers/users_controller.rb"
      assert files.none? { |file| file.start_with?("/") },
             "expected all finding paths to be target-root-relative, got: #{files.uniq}"

      report = File.read(report_path)
      assert_includes report, "# rails-audit report"
      assert_includes report, "## Security"
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
end
