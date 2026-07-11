# frozen_string_literal: true

require "test_helper"

class ActiveRecordDoctorParserTest < Minitest::Test
  REAL_OUTPUT = File.expand_path("../../fixtures/raw/active_record_doctor.txt", __dir__)

  def test_parses_seeded_findings_into_the_shared_finding_shape
    output = framed_output(
      unindexed_foreign_keys: [
        "add an index on users(account_id) - foreign keys are often used in database lookups " \
        "and should be indexed for performance reasons"
      ],
      missing_unique_indexes: [
        "add a unique index on users(email) - validating uniqueness in User without an index " \
        "can lead to duplicates"
      ]
    )

    findings = RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(output)

    unindexed = findings.find { |finding| finding.rule == "unindexed_foreign_keys" }
    assert_equal "active_record_doctor", unindexed.tool
    assert_equal "medium", unindexed.impact
    assert_equal "performance", unindexed.category
    assert_equal "medium", unindexed.confidence
    assert_equal "users.account_id", unindexed.context.fetch(:subject)
    assert_equal "db/schema.rb", unindexed.location.fetch(:file)

    unique = findings.find { |finding| finding.rule == "missing_unique_indexes" }
    assert_equal "high", unique.impact
    assert_equal "rails", unique.category
    assert_equal "medium", unique.confidence
    assert_equal "users.email", unique.context.fetch(:subject)
  end

  def test_clean_framed_report_returns_no_findings
    assert_empty RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(framed_output)
  end

  def test_parses_complete_real_output_from_the_synthetic_app
    findings = RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(File.read(REAL_OUTPUT))

    assert_equal 13, findings.size
    assert_equal 13, findings.map(&:id).uniq.size
    assert_equal({
      "incorrect_dependent_option" => 1,
      "missing_foreign_keys" => 2,
      "missing_presence_validation" => 2,
      "missing_unique_indexes" => 1,
      "table_without_timestamps" => 6,
      "unindexed_foreign_keys" => 1
    }, findings.group_by(&:rule).transform_values(&:size))
  end

  def test_changed_finding_wording_raises_with_raw_output
    output = framed_output(unindexed_foreign_keys: ["users.account_id needs an index now"])

    error = assert_raises(RailsAudit::Execution::UnexpectedActiveRecordDoctorOutputError) do
      RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(output)
    end

    assert_includes error.message, "users.account_id needs an index now"
    assert_includes error.raw_output, "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_BEGIN"
  end

  def test_missing_report_envelope_raises_instead_of_returning_empty
    raw_output = "rake aborted after loading the application"

    error = assert_raises(RailsAudit::Execution::UnexpectedActiveRecordDoctorOutputError) do
      RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(raw_output)
    end

    assert_equal raw_output, error.raw_output
  end

  def test_diagnostic_includes_stderr_without_parsing_it_as_report_content
    stdout = "incomplete stdout"
    diagnostics = "#{stdout}\nNoMethodError from detector on stderr"

    error = assert_raises(RailsAudit::Execution::UnexpectedActiveRecordDoctorOutputError) do
      RailsAudit::Execution::ActiveRecordDoctorParser.new.parse(
        stdout, diagnostic_output: diagnostics
      )
    end

    assert_equal diagnostics, error.raw_output
    assert_includes error.message, "NoMethodError from detector on stderr"
  end

  private

  def framed_output(findings = {})
    lines = ["RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_BEGIN 1"]
    detector_names.each do |detector|
      messages = findings.fetch(detector, [])
      status = messages.empty? ? "clean" : "findings"
      lines << "RAILS_AUDIT_DETECTOR_BEGIN #{detector}"
      lines.concat(messages)
      lines << "RAILS_AUDIT_DETECTOR_END #{detector} #{status}"
    end
    lines << "RAILS_AUDIT_ACTIVE_RECORD_DOCTOR_END"
    lines.join("\n") << "\n"
  end

  def detector_names
    RailsAudit::Execution::ActiveRecordDoctorParser::DETECTORS
  end
end
