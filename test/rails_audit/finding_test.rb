# frozen_string_literal: true

require "json"
require "test_helper"

class FindingTest < Minitest::Test
  def setup
    @attributes = {
      native_fingerprint: "native-123",
      tool: "brakeman",
      rule: "SQL Injection",
      category: "security",
      impact: "critical",
      confidence: "medium",
      message: "Possible SQL injection",
      location: {
        file: "app/models/story.rb",
        start_line: 716,
        end_line: 716,
        column: nil,
        lines: nil
      },
      context: { class: "Story", method: "update_score_and_recalculate!" }
    }
  end

  def test_computes_compound_identity_and_serializes_schema_v2
    finding = RailsAudit::Finding.new(**@attributes)

    assert_equal "48f1c0e3a24cece4", finding.id
    assert_equal @attributes[:location], finding.location
    assert_equal @attributes[:context], finding.context
    assert_equal(
      {
        id: "48f1c0e3a24cece4",
        native_fingerprint: "native-123",
        tool: "brakeman",
        rule: "SQL Injection",
        category: "security",
        impact: "critical",
        confidence: "medium",
        message: "Possible SQL injection",
        location: @attributes[:location],
        context: @attributes[:context]
      },
      finding.to_h
    )
    assert_equal JSON.parse(JSON.generate(finding.to_h)), JSON.parse(finding.to_json)
  end

  def test_is_an_immutable_value_object
    first = RailsAudit::Finding.new(**@attributes)
    second = RailsAudit::Finding.new(**@attributes)

    assert_equal first, second
    assert_equal first.hash, second.hash
    assert_predicate first, :frozen?
    assert_predicate first.location, :frozen?
    assert_predicate first.context, :frozen?
  end
end
